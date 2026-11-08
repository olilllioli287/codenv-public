import AppKit
import SwiftUI
import SwiftTerm
import WebKit

extension AppDelegate {
    func installTestHooksEarly(_ args: [String]) {
        // --pref "webFeaturesEnabled=0|1"：必須在 Store／Workspace 建立之前套用，只寫 <bundleID>.test。
        if args.contains("--state-dir") {
            for (i, flag) in args.enumerated() where flag == "--pref" && i + 1 < args.count {
                let pair = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                if pair[0] == "webFeaturesEnabled", ["0", "1"].contains(pair[1]) { Prefs.shared.webFeaturesEnabled = pair[1] == "1" }
                if pair[0] == "petEmbedCharacter" { PetEmbedPrefs.character = pair[1] }
                if pair[0] == "petEmbedPress", let n = Int(pair[1]) { PetEmbedPrefs.pressLevel = n }
                if pair[0] == "petEmbedOn" { PetEmbedPrefs.enabled = pair[1] == "1" }
                if pair[0] == "petSlotOn" { PetSlot.enabled = pair[1] == "1" }
                if pair[0] == "sidebarMode", ["commander", "tree"].contains(pair[1]) { Prefs.shared.sidebarMode = pair[1] }
                if pair[0] == "colorScheme", ["dark", "light", "system"].contains(pair[1]) { Prefs.shared.colorScheme = pair[1] }
            }
        }
        if args.contains("--dump-theme") {
            let t = Theme.fromITerm()
            print("字型", t.font.fontName, t.font.pointSize, "粗體", t.boldFont.fontName, "行距", t.lineSpacing)
            print("深色 背景", t.dark.bg, "文字", t.dark.fg)
            print("淺色 背景", t.light.bg, "文字", t.light.fg)
            exit(0)
        }
    }

    func testWebUnloadSeconds(_ args: [String]) -> TimeInterval {
        // 僅隔離資料的測試實例可縮短隱藏網頁的卸載時間。
        var webUnloadSeconds: TimeInterval = 180
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--web-unload-seconds"), i + 1 < args.count,
           let seconds = Double(args[i + 1]), seconds.isFinite, seconds > 0 {
            webUnloadSeconds = seconds
        }
        return webUnloadSeconds
    }

    /// 測試參數只在測試實例（有 --state-dir）生效：Astra 11/5 列出一長串會送訊息、改資料、開視窗的掛鉤沒檢查隔離，
    /// 誤用在正式 App 上會動到使用者的對話和設定。沒有 --state-dir 就全部忽略，記一行說明
    static func isolatedTestRun(_ args: [String], _ section: String) -> Bool {
        if args.contains("--state-dir") { return true }
        let known: Set<String> = ["--background", "--claude-home"]
        let flags = args.dropFirst().filter { $0.hasPrefix("--") && !known.contains($0) }
        if !flags.isEmpty {
            EventLog.log("測試", "沒有 --state-dir，忽略測試參數（\(section)）：\(flags.prefix(8).joined(separator: " "))")
            FileHandle.standardError.write(Data("codenv：沒有 --state-dir，忽略測試參數 \(flags.prefix(8).joined(separator: " "))\n".utf8))
        }
        return false
    }

    func installChatTestHooks(_ args: [String]) {
        guard Self.isolatedTestRun(args, "聊天") else { return }
        if let i = args.firstIndex(of: "--claude"), i + 1 < args.count { workspace.claudeCommand = args[i + 1] }
        // 背景 Session 閒置回收的門檻縮短（秒），測回收用
        if let i = args.firstIndex(of: "--bg-idle-seconds"), i + 1 < args.count, let sec = Double(args[i + 1]), sec > 0 { workspace.idleReleaseSeconds = sec }
        // 摘要測試完全不用真的 claude；讀不到假檔就回報失敗，不能退回花額度的路徑。第一則訊息另搭配 --chat-claude 假後端。
        if let i = args.firstIndex(of: "--handoff-fake"), i + 1 < args.count { Handoff.fakeFile = URL(fileURLWithPath: args[i + 1]) }
        // --chat-args "參數 參數"：測試時多給 claude 的參數（例如 --permission-mode default，逼它來問權限）
        if let i = args.firstIndex(of: "--chat-args"), i + 1 < args.count {
            ChatSession.extraArgs = args[i + 1].split(separator: " ").map(String.init)
        }
        if let i = args.firstIndex(of: "--chat-log"), i + 1 < args.count {
            FileManager.default.createFile(atPath: args[i + 1], contents: nil)
            ChatSession.log = FileHandle(forWritingAtPath: args[i + 1])
        }
    }

    func installFeedbackTestHooks(_ args: [String]) {
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--feedback-dump"), i + 1 < args.count {
            let log = args.firstIndex(of: "--feedback-log").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            Feedback.dump(to: args[i + 1], logFile: log)
        }
    }

    func installTestHooks(_ args: [String]) {
        guard Self.isolatedTestRun(args, "一般") else { return }
        // --float-term "秒:show|hide|newtab"／--dump-float "秒:檔案"：只操作隔離實例。
        for (i, flag) in args.enumerated() where ["--float-term", "--dump-float"].contains(flag) && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let terminal = self?.main.floatingTerminal else { return }
                if flag == "--dump-float" { terminal.dumpState(to: parts[1]); return }
                switch parts[1] {
                case "show": terminal.show()
                case "hide": terminal.hide()
                case "newtab": terminal.newTab()
                case "reset": terminal.resetGeometry()
                default: break
                }
            }
        }
        // --lid-sim "秒:動作"（要同時有 --lid-sim 旗標本身當開關，不碰真的闔蓋與 pmset）：
        //   動作 close／open／temp=N／batt=N／ac=0|1／helper=ok|unsupported|fail／work=N（覆蓋工作中的段數）／work=auto。
        // --lid-limits "撐多久秒,幾度,連續幾秒,幾秒記一行"：縮短時限方便測。
        for (i, a) in args.enumerated() where a == "--lid-limits" && i + 1 < args.count {
            let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
            DispatchQueue.main.async { [weak self] in
                guard let k = self?.main.lidKeeper, v.count >= 4 else { return }
                k.limits.maxHold = v[0]; k.limits.hotCelsius = v[1]; k.limits.hotSeconds = v[2]; k.limits.logEvery = v[3]
                if v.count > 4 { k.limits.preholdOffDelay = v[4] }
                if v.count > 5 { k.limits.statusEvery = v[5] }
                if v.count > 6 { k.limits.preholdRetry = v[6] }
            }
        }
        for (i, a) in args.enumerated() where a == "--lid-sim" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let k = self?.main.lidKeeper, let sim = k.env as? SimLidEnv else { return }
                let cmd = parts[1]
                let kv = cmd.split(separator: "=", maxSplits: 1).map(String.init)
                switch kv[0] {
                case "close": sim.closed = true
                case "open": sim.closed = false
                case "display": sim.external = kv.last == "1"
                case "temp": sim.temp = Double(kv.last ?? "") ?? sim.temp
                case "batt": sim.percent = Int(kv.last ?? "") ?? sim.percent
                case "ac": sim.onAC = kv.last == "1"
                case "helper": sim.helper = kv.last ?? "ok"
                case "work":
                    if let n = Int(kv.last ?? "") { k.workingCount = { n } }
                    else { k.workingCount = { [weak k] in k?.workingIDs().count ?? 0 } }
                case "jump":   // jump=秒：把 LidKeeper 的「現在」往前撥（模擬 Mac 睡過一覺，醒來兩次檢查間隔很長）
                    let add = Double(kv.last ?? "") ?? 0
                    let prev = k.now
                    k.now = { prev().addingTimeInterval(add) }
                    _ = prev
                case "recover": k.recoverIfNeeded()
                case "extdead": sim.connDead = true; sim.actualOn = false      // 小幫手重啟、連線斷了
                case "extoff": sim.actualOn = false      // 別人把小幫手的 nosleep 解除了
                default: break
                }
                k.log("（測試）\(cmd)")
            }
        }
        // --pet-key "秒:鍵碼[,shift]"／--pet-say "秒:倒數秒數:文字"／--pet-dump "秒:檔案"：嵌入桌寵的測試（模擬按鍵、泡泡、輸出狀態）
        for (i, a) in args.enumerated() where ["--pet-key", "--pet-say", "--pet-dump", "--pet-trace", "--pet-drag"].contains(a) && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let host = self?.main.host else { return }
                let pet = host.petEmbed
                switch a {
                case "--pet-key":
                    let f = parts[1].split(separator: ",").map(String.init)
                    if let code = Int64(f[0]) { PetKeys.shared.onKey?(code, f.count > 1 && f[1] == "shift") }
                case "--pet-trace":   // "秒:檔案"：從現在起每 20 ms 記一行 pose／下壓，共 1.5 秒
                    var lines: [String] = []; let t0 = Date()
                    Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
                        lines.append(String(format: "%.3f %@ %.2f", Date().timeIntervalSince(t0), pet.pose.rawValue, Double(pet.pressOffset)))
                        if Date().timeIntervalSince(t0) > 1.5 { t.invalidate(); try? lines.joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8) }
                    }
                case "--pet-drag":   // "秒:dx"：在桌寵上按住往左拖 dx 點再放開（走 NSApp.postEvent 事件佇列），測拖曳不會改右欄寬度
                    guard let w = pet.window, let host = self?.main.host else { return }
                    let center = pet.convert(NSPoint(x: pet.bounds.maxX - 40, y: pet.bounds.midY), to: nil)
                    let dx = Double(parts[1]) ?? 100
                    for (t, x, pr) in [(NSEvent.EventType.leftMouseDown, 0.0, Float(1)), (.leftMouseDragged, dx / 2, 1), (.leftMouseDragged, dx, 1), (.leftMouseUp, dx, 0)] {
                        if let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: center.x - x, y: center.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pr) { NSApp.postEvent(e, atStart: false) }
                    }
                    _ = host
                case "--pet-say":
                    pet.say(parts.count > 2 ? parts[2] : "", seconds: Int(parts[1]) ?? 0)
                default:
                    let f = pet.spriteFrame, e = pet.frame
                    let out: [String: Any] = ["enabled": PetEmbedPrefs.enabled, "character": PetEmbedPrefs.character, "press": PetEmbedPrefs.pressLevel,
                        "pose": pet.pose.rawValue, "pressOffset": Double(pet.pressOffset), "hidden": pet.isHidden || pet.superview == nil,
                        "embedFrame": [e.minX, e.minY, e.width, e.height], "columnWidth": Double(host.petColumnWidth), "cellPoints": Double(pet.cellPoints), "restY": Double(pet.restY), "panelWidth": Double(RightPanelModel.shared.width), "spriteFrame": [f.minX, f.minY, f.width, f.height],
                        "globalActive": PetKeys.shared.globalActive, "bubbleVisible": !pet.bubble.isHidden, "bubbleText": pet.bubble.text]
                    if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: parts[1])) }
                }
            }
        }
        // --pulse-dump "秒:檔案"：有幾個閃爍綠點登記了時鐘、時鐘有沒有在跑（測呼吸動畫只在工作中才掛上）
        for (i, a) in args.enumerated() where a == "--pulse-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let c = PulseClock.shared
                try? "users=\(c.users) running=\(c.isRunning) appActive=\(NSApp.isActive)\n".write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --return "秒數"：幾秒後模擬按一下鍵盤的 Return（走跟真的按鍵一樣的路）
        for (i, a) in args.enumerated() where a == "--return" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane,
                      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: self.main.window?.windowNumber ?? 0, context: nil,
                                               characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return }
                p.terminal.keyDown(with: e)
            }
        }
        // --drop "秒數:路徑"：幾秒後模擬把這個檔案拖進目前那格
        for (i, a) in args.enumerated() where a == "--drop" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                p.pastePaths([url])
            }
        }
        // --front "秒數:持續秒數"：幾秒後把視窗短暫放到最前面（不搶焦點），給外面的截圖工具拍，時間到退回後面
        for (i, a) in args.enumerated() where a == "--front" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let w = self?.main.window else { return }
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[1]) { w.orderBack(nil) }
            }
        }
        // --main-frame "秒數:x:y:寬:高:持續秒數"：把主視窗搬到這個位置（螢幕座標、左下原點）並放到最前面（不搶焦點、不 activate），時間到退回後面。給真滑鼠測試用（只 --state-dir 生效）
        for (i, a) in args.enumerated() where a == "--main-frame" && i + 1 < args.count && args.contains("--state-dir") {
            let n = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard n.count == 6 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + n[0]) { [weak self] in
                guard let w = self?.main.window else { return }
                w.setFrame(NSRect(x: n[1], y: n[2], width: n[3], height: n[4]), display: true)
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + n[5]) { w.orderBack(nil) }
            }
        }
        // --front-detached：（只 --state-dir 生效）--background 時獨立視窗被壓在最後面、點不到；加這個，每出現一個新的獨立視窗就把它放到最前面並設成鍵盤焦點（給真滑鼠測試用）
        if args.contains("--front-detached"), args.contains("--state-dir") {
            var seen = Set<UUID>()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                for (id, c) in self.main.detachedWindows where !seen.contains(id) {
                    seen.insert(id)
                    c.window?.makeKeyAndOrderFront(nil)
                }
                seen = seen.filter { self.main.detachedWindows[$0] != nil }
            }
        }
        // --focus-settings "秒數"：打開設定視窗、把 App 叫到前面讓設定變成作用中的視窗（測 ⌘ W 關小視窗；會搶鍵盤焦點）
        for (i, a) in args.enumerated() where a == "--focus-settings" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                self?.showSettings()
                NSApp.activate(ignoringOtherApps: true)
                self?.settings?.window?.makeKeyAndOrderFront(nil)
            }
        }
        // --key-keys "秒數:按鍵 …"：跟 --keys 一樣，但送到當下作用中的視窗（例如設定視窗）
        for (i, a) in args.enumerated() where a == "--key-keys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let w = NSApp.keyWindow else { return }
                for (n, t) in tokens.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) }
                }
            }
        }
        // --spring "秒數:第幾個分頁（從 0 數）:停幾秒"：像拖著檔案停在那個分頁上，時間到移開（測 1.5 秒切 Window）
        for (i, a) in args.enumerated() where a == "--spring" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                self?.main.host.tabBar.springHover(tab: Int(parts[1]))
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[2]) { self?.main.host.tabBar.springHover(tab: nil) }
            }
        }
        // --spring-sample "起始秒:間隔毫秒:次數:檔"：每隔一段時間把分頁列的彈簧狀態（等、亮）和目前是第幾個 Window 寫進檔案
        for (i, a) in args.enumerated() where a == "--spring-sample" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let ms = Double(parts[1]), let n = Int(parts[2]) else { continue }
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec + Double(k) * ms / 1000) { [weak self] in
                    guard let self else { return }
                    let line = String(format: "t+%.0fms ", Double(k) * ms) + self.main.host.tabBar.springState() + " 目前=\(self.store.windowIndex ?? -1)" + (k == n - 1 ? " 事件=" + TabBar.springLog.map { String(format: "%@@%.0fms", $0.0, ($0.1 - (TabBar.springLog.first?.1 ?? 0)) * 1000) }.joined(separator: " ") : "") + "\n"
                    if let h = FileHandle(forWritingAtPath: parts[3]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[3], atomically: true, encoding: .utf8) }
                }
            }
        }
        // --hover-title "秒:第幾段對話:停幾秒"：像滑鼠停在那格的標題上（停留小卡）；--hover-sample "起始秒:間隔毫秒:次數:第幾段對話:檔" 取樣小卡狀態
        for (i, a) in args.enumerated() where a == "--hover-title" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, self.store.conversations.indices.contains(Int(parts[1])) else { return }
                let id = self.store.conversations[Int(parts[1])].id
                self.main.host.testHover(id, inside: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[2]) { self.main.host.testHover(id, inside: false) }
            }
        }
        for (i, a) in args.enumerated() where a == "--hover-sample" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 4).map(String.init)
            guard parts.count == 5, let sec = Double(parts[0]), let ms = Double(parts[1]), let n = Int(parts[2]), let ci = Int(parts[3]) else { continue }
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec + Double(k) * ms / 1000) { [weak self] in
                    guard let self, self.store.conversations.indices.contains(ci) else { return }
                    let line = String(format: "t+%.0fms ", Double(k) * ms) + self.main.host.testInfoState(self.store.conversations[ci].id) + "\n"
                    if let h = FileHandle(forWritingAtPath: parts[4]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[4], atomically: true, encoding: .utf8) }
                }
            }
        }
        // --stop-test "秒:模式:檔"：對第一段有掃到外部程序的對話，停它的第一個項目。模式 real＝照一般的停；wrongtime＝把啟動時間改成別的時間（模擬 pid 被重用），不能送任何訊號。結果（項目 pid、訊號記錄、那一列有沒有被拿掉）寫進檔案
        for (i, a) in args.enumerated() where a == "--stop-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let act = SessionActivity.shared
                if parts[1] == "event" {   // 事件追到的背景指令：走 stop_task（假 claude 把收到的 stdin 記下來）
                    guard let c = self.store.conversations.first(where: { !(act.background[$0.id] ?? []).isEmpty }), let it = act.background[c.id]?.first else { try? "沒有背景工作\n".write(toFile: parts[2], atomically: true, encoding: .utf8); return }
                    var out = "項目 id=\(it.id) 可停=\(act.canStop(it))\n"
                    act.stop(it, conversation: c.id) { out += "訊號：\($0)\n" }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { try? out.write(toFile: parts[2], atomically: true, encoding: .utf8) }
                    return
                }
                guard let c = self.store.conversations.first(where: { !(act.scanned[$0.id] ?? []).isEmpty }), var it = act.scanned[c.id]?.first else { try? "沒有掃到項目\n".write(toFile: parts[2], atomically: true, encoding: .utf8); return }
                var out = "項目 pid=\(it.pid ?? -1) 項目數=\(act.scanned[c.id]?.count ?? 0)\n"
                let real = it
                if parts[1] == "wrongtime" { it = RunningItem(id: it.id, text: it.text, since: it.since.addingTimeInterval(-500), background: true, kind: "bash", pid: it.pid, tag: it.tag) }
                act.stop(it, conversation: c.id) { out += "訊號：\($0)\n" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    out += "1.5 秒後：程序還在=\(ProcessScan.startTime(of: real.pid ?? 0) != nil) 這列還在=\(act.scanned[c.id]?.contains { $0.id == real.id } == true)\n"
                    try? out.write(toFile: parts[2], atomically: true, encoding: .utf8)
                }
            }
        }
        // --show "秒數:第幾段對話"：像在側欄點一下那段對話
        for (i, a) in args.enumerated() where a == "--show" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, Int(parts[1]) < self.store.conversations.count else { return }
                self.store.show(self.store.conversations[Int(parts[1])].id)
            }
        }
        // --new-codelab "秒數"：像按側欄程式碼學習專區的「新的練習」
        for (i, a) in args.enumerated() where a == "--new-codelab" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newCodeLabConversation() }
        }
        // --tab-rects "秒數:檔案"：每個分頁在螢幕上的位置（x y w h，螢幕座標、左下原點）
        for (i, a) in args.enumerated() where a == "--tab-rects" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let s = self.main.host.tabBar.tabScreenRects().map { "\($0.minX) \($0.minY) \($0.width) \($0.height)" }.joined(separator: "\n")
                try? s.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --dump-windows "秒數:檔案"：設定視窗開著沒、每個 Session 的 Window 名稱、作用中的是哪個視窗
        for (i, a) in args.enumerated() where a == "--dump-windows" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let key = NSApp.keyWindow.map { $0 === self.main.window ? "主視窗" : $0 === self.settings?.window ? "設定" : $0.title } ?? "（無）"
                let fr = self.main.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                let s = "settings=\(self.settings?.window?.isVisible == true) key=\(key) active=\(NSApp.isActive) mainKey=\(self.main.window?.isKeyWindow == true) focus=\(fr) pane=\(self.store.currentWindow?.focused.map { String($0.uuidString.suffix(4)) } ?? "nil") windows=\(self.store.sessions.map { $0.windows.map(\.name) })\n"
                try? s.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --open-settings "秒數:持續秒數"：幾秒後打開設定視窗、短暫放到最前面（不搶焦點）給截圖工具拍，時間到退回後面
        for (i, a) in args.enumerated() where a == "--open-settings" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                self?.showSettings()
                guard let w = self?.settings?.window else { return }
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[1]) { w.orderBack(nil) }
            }
        }
        // --bang-dump "秒數:檔案"：目前聊天室的 ! 指令紀錄寫成 JSON；--bang-stop "秒數"：按停止；--bang-dismiss "秒數"：按輸入框上面的 ✕
        // （用 --chat-send "秒數:! 指令" 從輸入框的路徑執行；--bang-timeout 秒數 縮短逾時）
        for (i, a) in args.enumerated() where (a == "--bang-dump" || a == "--bang-stop" || a == "--bang-dismiss") && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard let sec = Double(parts[0]) else { continue }
            let path = parts.count == 2 ? String(parts[1]) : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                switch a {
                case "--bang-dump": try? p.bangDump.write(toFile: path, atomically: true, encoding: .utf8)
                case "--bang-stop": p.stopBang()
                default: p.dismissBang()
                }
            }
        }
        // --chat-send "秒數:文字"：幾秒後在聊天框打這些字並送出（\\n 代表換行）
        // --bg-send "秒數:資料夾:文字|<clear>"：對那個資料夾的聊天格（可以是隱藏、網頁已卸載的）程式代送，跟排程／交接同一條路
        // --web-probe "秒數:資料夾:輸出檔"：那格網頁在不在、畫面文字（只在 --state-dir）
        for (i, a) in args.enumerated() where (a == "--bg-send" || a == "--web-probe") && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let dir = URL(fileURLWithPath: parts[1]).standardizedFileURL.resolvingSymlinksInPath().path
                let conv = self.store.conversations.first { c in
                    self.store.project(c.projectID).map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == dir } ?? false
                }
                guard let conv, let pane = self.workspace.panes[conv.id] as? ChatPane else {
                    let have = self.store.conversations.map { c in "\(self.store.project(c.projectID)?.path ?? "?") pane=\(self.workspace.panes[c.id].map { "\(type(of: $0))" } ?? "nil")" }
                    if a == "--web-probe" { try? "沒有那格\n\(have.joined(separator: "\n"))\n".write(toFile: parts[2], atomically: true, encoding: .utf8) }
                    return
                }
                if a == "--bg-send" {
                    if parts[2] == "<clear>" { pane.inputBar.textView.string = ""; pane.inputBar.textView.didChangeText() }   // 清空那格輸入框（測卸載用）
                    else if parts[2].hasPrefix("<notice>") { pane.notice(String(parts[2].dropFirst(8))) }   // 對那格發一則提示（測提示保留）
                    else { _ = pane.sendText(parts[2]) }
                    return
                }
                pane.testWebText { text in
                    let out = "hasWeb=\(pane.hasWeb) inWindow=\(pane.window != nil)\nnotices=\(pane.pendingNoticeCount)\n--text--\n\(text)\n"
                    try? out.write(toFile: parts[2], atomically: true, encoding: .utf8)
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--chat-send" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.onSend?()
            }
        }
        // --chat-send-conv "秒數:第幾段:文字"：把文字送到第 n 段對話（從 0 數，不管有沒有被選取；它要有開著的格子）。每日交接的「正在回答」測試用
        for (i, a) in args.enumerated() where a == "--chat-send-conv" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, self.store.conversations.indices.contains(n),
                      let c = self.store.conversation(self.store.conversations[n].id),
                      let p = self.workspace.pane(for: c) as? ChatPane else { return }
                _ = p.sendText(parts[2])
            }
        }
        // --tab-test "秒數:檔案"：在幾種焦點下呼叫「輸入框外按 Tab」，結果寫進檔案（Tab 只在對話內容上採用建議，其他地方照常）
        for (i, a) in args.enumerated() where a == "--tab-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window,
                      let (id, p) = self.workspace.panes.compactMap({ k, v in (v as? ChatPane).map { (k, $0) } }).first else { return }
                self.store.setFocus(id)
                let tv = p.inputBar.textView
                guard let web = p.subviews.first(where: { $0 is WKWebView }) else { return }
                var out: [String] = []
                func run(_ name: String, focus: NSView?, expect: Bool) {
                    tv.string = ""; tv.suggestion = "測試建議"
                    if let focus { w.makeFirstResponder(focus) }
                    let r = self.main.tabSuggestion(from: w)
                    out.append("\(r == expect ? "OK " : "NG ") \(name)：攔了=\(r) 輸入框=「\(tv.string)」")
                }
                run("焦點在對話內容", focus: web, expect: true)
                run("焦點在輸入框本身（交給輸入框自己）", focus: tv, expect: false)
                // 聊天室裡可輸入的地方（程式碼區編輯器、看板輸入框也是可編輯的 NSTextView）
                let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20)); p.addSubview(editor)
                run("焦點在聊天室裡的可編輯文字區（程式碼區編輯器）", focus: editor, expect: false)
                editor.removeFromSuperview()
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20)); w.contentView?.addSubview(field)
                run("焦點在主視窗別的輸入欄（看板輸入框）", focus: field, expect: false)
                field.removeFromSuperview()
                if let b = BrowserPane.all.first { run("焦點在瀏覽器格", focus: b.webView, expect: false) }
                w.makeFirstResponder(web)
                tv.string = "已經有字"; let r1 = self.main.tabSuggestion(from: w); out.append("\(r1 ? "NG" : "OK ") 輸入框已經有字：攔了=\(r1)")
                tv.string = ""; tv.suggestion = nil; let r2 = self.main.tabSuggestion(from: w); out.append("\(r2 ? "NG" : "OK ") 沒有建議：攔了=\(r2)")
                self.showSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.settings?.window?.makeKey()
                    tv.suggestion = "測試建議"; w.makeFirstResponder(web)
                    let r3 = self.main.tabSuggestion(from: self.settings?.window)
                    out.append("\(r3 ? "NG" : "OK ") 在設定視窗按 Tab：攔了=\(r3)")
                    try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --pane-close-test "秒數:檔案"：前三段對話排成三格（比例 0.3／0.6），紫框在中間按 ⌘ W、⌘ ⇧ T，再關到剩一格、關 Window、找回，結果寫進檔案
        for (i, a) in args.enumerated() where a == "--pane-close-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let s = self.store, s.conversations.count >= 3 else { return }
                let ids = Array(s.conversations.prefix(3).map(\.id))
                let (a, b, c) = (ids[0], ids[1], ids[2])
                let name = { (id: UUID?) in id.flatMap { x in ids.firstIndex(of: x).map { ["A", "B", "C"][$0] } } ?? "nil" }
                var out: [String] = []
                func ok(_ cond: Bool, _ msg: String) { out.append((cond ? "OK  " : "NG  ") + msg) }
                let orig: PaneNode = .split(vertical: false, ratio: 0.3, a: .leaf(a), b: .split(vertical: false, ratio: 0.6, a: .leaf(b), b: .leaf(c)))
                for id in ids { s.unplace(id) }
                s.editWindow { w in w.root = orig; w.focused = b }
                let windowsBefore = s.sessions.first?.windows.count ?? 0
                let bURL = s.conversation(b)?.browser
                ok(true, "B 是瀏覽器格子=\(bURL != nil)")
                s.closePaneOrWindow()
                let leaves = s.currentWindow?.root?.leaves ?? []
                ok(leaves == [a, c], "⌘ W 後剩 \(leaves.map { name($0) })")
                ok(s.currentWindow?.focused == a || s.currentWindow?.focused == c, "焦點移到 \(name(s.currentWindow?.focused))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    ok(self.workspace.panes[b] == nil && !BrowserPane.all.contains { $0.conversationID == b }, "關掉的瀏覽器格子已停掉（3 秒後）")
                    ok(s.conversation(b) != nil, "B 還在側欄")
                    ok(s.reopenClosedWindow(), "⌘ ⇧ T 有東西可以找回")
                    ok(s.currentWindow?.root == orig, "B 放回原位、比例一樣")
                    ok(s.currentWindow?.focused == b, "焦點回到 B")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        let bp = BrowserPane.all.first { $0.conversationID == b }
                        ok(bp?.currentURL == bURL, "B 重新打開回到原網址：\(bp?.currentURL ?? "沒有")")
                        // 關到剩一格，再 ⌘ W 關整個 Window，找回
                        s.closePaneOrWindow(); s.closePaneOrWindow()
                        ok((s.currentWindow?.root?.leaves.count ?? 0) == 1, "連按兩次 ⌘ W 剩一格")
                        let lone = s.currentWindow?.root?.leaves.first
                        let wid = s.currentWindow?.id
                        s.closePaneOrWindow()
                        ok(!(s.sessions.first?.windows.contains { $0.id == wid } ?? true), "只剩一格時 ⌘ W 關掉整個 Window（Window 數 \(windowsBefore) → \(s.sessions.first?.windows.count ?? 0)，空的補上一個）")
                        ok(s.reopenClosedWindow(), "⌘ ⇧ T 找回 Window")
                        ok(s.currentWindow?.id == wid && s.currentWindow?.root?.leaves == [lone!], "找回的是同一個 Window、裡面是 \(name(lone))")
                        ok(s.reopenClosedWindow() && s.reopenClosedWindow(), "再按兩次 ⌘ ⇧ T 把前面關的兩格也找回")
                        ok(Set(s.currentWindow?.root?.leaves ?? []) == Set(ids), "三格都回來了：\((s.currentWindow?.root?.leaves ?? []).map { name($0) })")
                        ok(s.currentWindow?.root == orig, "版面跟一開始一樣")
                        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --agy-net-test "秒數:檔案"：斷網判斷的各層結果寫進檔案（配 --agy-offline、--agy-check-host 用）
        for (i, a) in args.enumerated() where a == "--agy-net-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                DispatchQueue.global().async {
                    var out = ["quickOK=\(AgyNet.quickOK)", "canCall=\(AgyNet.canCall())"]
                    // 假的 agy 紀錄：走到互動登入 → 之後 30 分鐘都不叫
                    let log = AgyNet.newLogFile()
                    try? "I1025 printmode.go:409] Print mode: silent auth failed\nI1025 printmode.go:426] Print mode: triggering interactive OAuth\n".write(to: log, atomically: true, encoding: .utf8)
                    AgyNet.check(log: log)
                    out.append("跳過登入頁之後 quickOK=\(AgyNet.quickOK) canCall=\(AgyNet.canCall()) 紀錄檔刪了=\(!FileManager.default.fileExists(atPath: log.path))")
                    try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --finder-test "秒數:檔案"：點路徑時 Finder 會怎麼顯示（只算結果，不真的開 Finder）
        for (i, a) in args.enumerated() where a == "--finder-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let home = NSHomeDirectory()
                let cases = ["/etc/hosts", "/usr/bin",
                             "/Applications/Google Chrome.app", home + "/Documents/沒有這個/檔案.md", "/no/such/dir/x.txt"]
                let out = cases.map { c -> String in
                    let t = ChatPane.finderTarget(URL(fileURLWithPath: c))
                    return "\(c) → \(t.select ? "選起來" : "打開") \(t.url.path)"
                }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --new-browser "秒數"：像按側欄的「瀏覽器」
        for (i, a) in args.enumerated() where a == "--new-browser" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newBrowser() }
        }
        // --browser-test "秒數:動作:參數"：對目前選中的瀏覽器格子做事（紀錄寫進 state-dir/browser-test.log）
        //   zoom:+ 或 zoom:-（同 ⌘ + / ⌘ −）、load:網址或 file://…、drop:檔案路徑（假的 Finder 拖放，不動真滑鼠）、click:x,y（網頁座標，事件直接送給 WKWebView）
        for (i, a) in args.enumerated() where a == "--browser-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let b = self.workspace.panes[id] as? BrowserPane else { return }
                let logURL = self.store.directory.appendingPathComponent("browser-test.log")
                let log: (String) -> Void = { line in
                    let d = Data((line + "\n").utf8)
                    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: logURL) }
                }
                switch parts[1] {
                case "load": b.load(parts[2])
                case "drop": FakeFileDrag.run(files: [URL(fileURLWithPath: parts[2])], onto: b.webView, log: log)
                case "click":
                    let xy = parts[2].split(separator: ",").compactMap { Double($0) }
                    guard xy.count == 2, let win = b.window else { return }
                    let w = b.webView
                    let pt = w.convert(NSPoint(x: xy[0], y: w.isFlipped ? xy[1] : w.bounds.height - xy[1]), to: nil)
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                        if t == .leftMouseDown { w.mouseDown(with: e) } else { w.mouseUp(with: e) }
                    }
                    log("click \(xy) 已送出")
                case "eval":    // 在網頁裡跑一段 JS，結果寫進紀錄（測試用）
                    b.webView.evaluateJavaScript(parts[2]) { r, e in log("eval → \(r.map { "\($0)" } ?? "nil")\(e.map { " 錯誤：\($0.localizedDescription)" } ?? "")") }
                case "skin":    // Gemini 換皮：on／off＝像設定頁開關；light／dark＝把 App 外觀切成淺／深色再重套（顏色變數跟主題走）
                    switch parts[2] {
                    // 只換 App 外觀、不手動重套：靠 GeminiSkin.startObservingAppearance 的監聽自己重套（測 K1／K2）
                    case "light": NSApp.appearance = NSAppearance(named: .aqua)
                    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                    case "nlm-on", "nlm-off": Prefs.shared.notebookSkin = parts[2] == "nlm-on"
                    default: Prefs.shared.geminiSkin = parts[2] == "on"
                    }
                    log("skin \(parts[2])")
                case "zoom": b.zoom(parts[2] == "-" ? -1 : 1); log("pageZoom \(b.webView.pageZoom)")
                case "sheet":   // 看視窗上有沒有掛著選檔視窗；有就按取消收掉
                    let sh = b.window?.attachedSheet
                    log("sheet：\(sh.map { String(describing: type(of: $0)) } ?? "沒有")")
                    if let sh { b.window?.endSheet(sh, returnCode: .cancel) }
                default: break
                }
            }
        }
        // --browser-shot "秒數:檔.png"：把目前選中的瀏覽器格子的「網頁內容」拍成 PNG（--snapshot 拍不到 WKWebView 的內容，這個用 takeSnapshot）
        for (i, a) in args.enumerated() where a == "--browser-shot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let b = self.workspace.panes[id] as? BrowserPane else { return }
                b.snapshot { data in if let data { try? data.write(to: URL(fileURLWithPath: parts[1])) } }
            }
        }
        // --input-text "秒數:文字"：幾秒後在聊天框打這些字但不送出（\\n 代表換行；看長文字會不會碰到下面的狀態列）
        for (i, a) in args.enumerated() where a == "--input-text" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.didChangeText()
            }
        }
        // --input-files "秒數:路徑|路徑…"：幾秒後像把這些檔案拖進聊天框（圖片變縮圖、其他變檔案卡片）
        for (i, a) in args.enumerated() where a == "--input-files" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let urls = parts[1].split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let imgs = urls.filter(ChatTextView.isImage), others = urls.filter { !ChatTextView.isImage($0) }
                if !imgs.isEmpty { p.inputBar.attach(urls: imgs, images: []) }
                p.inputBar.insertPaths(others)
            }
        }
        // --input-key "秒數:游標[+選取長度]:keyCode"：幾秒後把游標放到那裡、在 App 裡直接送一個按鍵給輸入框（不經系統，不動真的鍵盤）
        // 例：51＝delete、117＝往後刪、123／124＝← →；位置 -1＝最後面
        for (i, a) in args.enumerated() where a == "--input-key" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let code = UInt16(parts[2]) else { continue }
            let sel = parts[1].split(separator: "+").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane, let w = p.window else { return }
                let tv = p.inputBar.textView
                let n = (tv.string as NSString).length
                let loc = (sel.first ?? -1) < 0 ? n : min(n, sel[0])
                tv.setSelectedRange(NSRange(location: loc, length: min(n - loc, sel.count > 1 ? sel[1] : 0)))
                let ch = code == 51 ? "\u{7f}" : code == 117 ? "\u{f728}" : code == 123 ? "\u{f702}" : code == 124 ? "\u{f703}" : ""
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                            context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                    tv.keyDown(with: e)
                }
            }
        }
        // --dump-input "秒數:檔案"：把目前聊天室輸入框裡的字寫進檔案（測 ⌃ C 放回）
        for (i, a) in args.enumerated() where a == "--dump-input" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let fr = p.window?.firstResponder
                let where_ = fr === p.inputBar.textView ? "輸入框" : fr.map { "\(type(of: $0))" } ?? "無"
                try? "busy=\(p.inputBar.busy) hasQuotes=\(p.inputBar.hasQuotes) focus=\(where_) \(p.inputBar.scrollerState) suggestion=\(p.inputBar.suggestion ?? "（無）") undo=\(p.inputBar.textView.undoManager?.canUndo == true)/\(p.inputBar.textView.undoManager?.canRedo == true) sel=\(p.inputBar.textView.selectedRange().location) text=\(p.inputBar.textView.string)\n".write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --focus-input "秒數"：把 App 叫到前面、焦點放進輸入框（測選單快捷鍵 ⌘ Z、⌘ X 要有作用中的視窗；會搶走鍵盤焦點）
        for (i, a) in args.enumerated() where a == "--focus-input" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.main.window?.makeKeyAndOrderFront(nil)
                self.main.window?.makeFirstResponder(p.inputBar.textView)
            }
        }
        // --blur-input "秒數"：像 Claude 沒在做時按 Esc（離開輸入框），但 Claude 在做時也能用
        for (i, a) in args.enumerated() where a == "--blur-input" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.onBlur?()
            }
        }
        // --set-input "秒數:文字"：只把字放進輸入框（不送出、不移焦點）
        for (i, a) in args.enumerated() where a == "--set-input" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
                p.inputBar.textView.didChangeText()
            }
        }
        // --input-click-last "秒數:檔案"：點輸入框最後一行（最後是空行時點那個空行）的中間，記下點到哪個元件、游標停在哪、文字區高度
        for (i, a) in args.enumerated() where a == "--input-click-last" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let pane = self.workspace.panes[id] as? ChatPane,
                      let tv = pane.inputBar.textView as NSTextView?, let lm = tv.layoutManager, let tc = tv.textContainer, let w = tv.window else { return }
                // 檔名含 long：放 20 行（最後是空行），超過最多行數、要捲動
                if parts[1].contains("long") { tv.string = (1...20).map { "第\($0)行" }.joined(separator: "\n") + "\n"; tv.didChangeText() }
                else if tv.string.isEmpty { tv.string = "第一行\n第二行\n"; tv.didChangeText() }
                lm.ensureLayout(for: tc)
                let len = (tv.string as NSString).length
                tv.setSelectedRange(NSRange(location: 0, length: 0))      // 游標先放最前面＝「上次的位置」
                tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
                let viaQueue = parts[1].contains("queue")    // 檔名含 queue：先把焦點交給聊天網頁，點擊走 NSApp.postEvent（會經過 WindowHost 的滑鼠監聽）
                var pre = "焦點前 textView高=\(Int(tv.frame.height)) 可視=\(Int(tv.visibleRect.minY))..\(Int(tv.visibleRect.maxY)) 框=\(Int(pane.inputBar.frame.height))\n"
                if viaQueue, let web = Self.find(DropWebView.self, in: pane) { w.makeFirstResponder(web) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (viaQueue ? 0.4 : 0)) {
                lm.ensureLayout(for: tc)
                pre += "焦點給網頁後 textView高=\(Int(tv.frame.height)) 可視=\(Int(tv.visibleRect.minY))..\(Int(tv.visibleRect.maxY)) 框=\(Int(pane.inputBar.frame.height)) 游標=\(tv.selectedRange().location)\n"
                var r = lm.extraLineFragmentRect
                let hasExtra = r.height > 0
                if !hasExtra, lm.numberOfGlyphs > 0 { r = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil) }
                var pt = NSPoint(x: r.minX + 20 + tv.textContainerOrigin.x, y: r.midY + tv.textContainerOrigin.y)
                // 檔名含 below：點文字框下緣再往下 4 點（圓角框的空白）；含 margin：點輸入列最左邊的外圍留白（同高度）
                if parts[1].contains("below") { pt.y = tv.visibleRect.maxY + 4 }
                var wp = tv.convert(pt, to: nil)
                if parts[1].contains("margin") { wp.x = pane.inputBar.convert(NSPoint(x: 6, y: 0), to: nil).x }
                // 檔名含 race：先假裝點了對話內容（排了 50ms 後把焦點交給網頁），馬上點回輸入框
                if parts[1].contains("race"), let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: w.frame.height - 60), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    w.makeFirstResponder(tv); pane.clickedInside(e)
                }
                let hit = w.contentView?.hitTest(w.contentView!.convert(wp, from: nil))
                var log = pre + "len=\(len) 結尾空行=\(hasExtra) 行=\(Int(r.minY))..\(Int(r.maxY)) textView高=\(Int(tv.frame.height)) 可視=\(Int(tv.visibleRect.minY))..\(Int(tv.visibleRect.maxY)) 點到=\(hit.map { String(describing: type(of: $0)) } ?? "nil")\n"
                log += "直接算 index=\(tv.characterIndexForInsertion(at: pt)) pt=\(Int(pt.x)),\(Int(pt.y)) wp=\(Int(wp.x)),\(Int(wp.y))\n"
                if viaQueue {
                    var mon: Any?
                    mon = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
                        let q = tv.convert(e.locationInWindow, from: nil)
                        log += "事件 \(e.type == .leftMouseDown ? "down" : "up") 視窗點=\(Int(e.locationInWindow.x)),\(Int(e.locationInWindow.y)) 換到文字框=\(Int(q.x)),\(Int(q.y)) 游標=\(tv.selectedRange().location)\n"
                        DispatchQueue.main.async { log += "  處理後 游標=\(tv.selectedRange().location)\n" }
                        if e.type == .leftMouseUp, let m = mon { NSEvent.removeMonitor(m); mon = nil }
                        return e
                    }
                    for (t, pr) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                        if let e = NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pr) { NSApp.postEvent(e, atStart: false) }
                    }
                } else if let hit {
                    if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) { NSApp.postEvent(up, atStart: true) }
                    if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { hit.mouseDown(with: down) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    log += "游標=\(tv.selectedRange().location)（應該是 \(len)） 焦點=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")\n"
                    try? log.write(toFile: parts[1], atomically: true, encoding: .utf8)
                }
                }
            }
        }
        // --chat-send-now "秒數:文字"：像按 ⌃ Enter（Claude 還在做的話馬上插話）
        for (i, a) in args.enumerated() where a == "--chat-send-now" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.onSendNow?()
            }
        }
        // --gemini-selftest "檔案"：Gemini 匯出下載圖片的純邏輯自測（cookie 篩選、轉址限制、session 的 cookie 不外漏），結果寫進檔案；不連網
        for (i, a) in args.enumerated() where a == "--gemini-selftest" && i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var out: [String] = []
                func check(_ name: String, _ ok: Bool) { out.append("\(ok ? "OK " : "NG ") \(name)") }
                func cookie(_ domain: String, _ name: String) -> HTTPCookie {
                    HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v", .secure: "TRUE"])!
                }
                let all = [cookie(".google.com", "SID"), cookie("lh3.googleusercontent.com", "A"), cookie(".googleusercontent.com", "B"), cookie("accounts.google.com", "C"),
                           cookie(".gstatic.com", "D"), cookie("example.com", "X"), cookie("evil-google.com", "Y"), cookie("notgoogle.com", "Z"), cookie(".google.com.evil.com", "W")]
                let kept = Set(GeminiExport.googleCookies(all).map(\.name))
                check("cookie 篩選：只留 Google 自家網域（SID A B C D），結果=\(kept.sorted())", kept == ["SID", "A", "B", "C", "D"])
                check("isGoogleHost：google.com／lh3.google.com／lh3.googleusercontent.com 是", ["google.com", "lh3.google.com", "lh3.googleusercontent.com"].allSatisfy(GeminiExport.isGoogleHost))
                check("isGoogleHost：evil-google.com／google.com.evil.com／notgoogle.com 不是", ["evil-google.com", "google.com.evil.com", "notgoogle.com"].allSatisfy { !GeminiExport.isGoogleHost($0) })
                let del = GeminiExport.SameGoogleRedirect()
                let sess = URLSession(configuration: .ephemeral), task = sess.dataTask(with: URL(string: "https://lh3.googleusercontent.com/gg/x")!)
                let resp = HTTPURLResponse(url: URL(string: "https://lh3.googleusercontent.com/gg/x")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
                func redirect(_ u: String) -> Bool {
                    var allowed = false
                    del.urlSession(sess, task: task, willPerformHTTPRedirection: resp, newRequest: URLRequest(url: URL(string: u)!)) { allowed = $0 != nil }
                    return allowed
                }
                check("轉址：https://lh3.google.com/rd-gg/x 放行", redirect("https://lh3.google.com/rd-gg/x"))
                check("轉址：http://lh3.google.com 不放行（不是 https）", !redirect("http://lh3.google.com/x"))
                check("轉址：https://evil.com／https://google.com.evil.com 不放行", !redirect("https://evil.com/x") && !redirect("https://google.com.evil.com/x"))
                let before = HTTPCookieStorage.shared.cookies?.count ?? 0
                let session = GeminiExport.downloadSession(cookies: GeminiExport.googleCookies(all))
                let store = session.configuration.httpCookieStorage
                let toGoogle = Set((store?.cookies(for: URL(string: "https://lh3.google.com/rd-gg/x")!) ?? []).map(\.name))
                let toUser = Set((store?.cookies(for: URL(string: "https://lh3.googleusercontent.com/gg/x")!) ?? []).map(\.name))
                let toOther = store?.cookies(for: URL(string: "https://example.com/")!) ?? []
                check("session cookie：lh3.google.com 會帶 SID，結果=\(toGoogle.sorted())", toGoogle.contains("SID"))
                check("session cookie：lh3.googleusercontent.com 會帶 A B，結果=\(toUser.sorted())", toUser.isSuperset(of: ["A", "B"]))
                check("session cookie：example.com 一個都不帶", toOther.isEmpty)
                check("HTTPCookieStorage.shared 沒被動到（\(before) → \(HTTPCookieStorage.shared.cookies?.count ?? 0)）", (HTTPCookieStorage.shared.cookies?.count ?? 0) == before)
                let sum = GeminiExport.cookieSummary([cookie(".google.com", "__Secure-1PSID"), cookie(".google.com", "SID"), cookie("accounts.google.com", "__Host-GAPS")])
                let doms = sum["domains"] as? [String: [String: Int]] ?? [:]
                check("cookie 摘要：總數 3、.google.com 有 2 個其中 1 個 __Secure-、accounts.google.com 有 1 個 __Host-，且不含 cookie 值", sum["total"] as? Int == 3 && doms[".google.com"]?["count"] == 2 && doms[".google.com"]?["secure-prefix"] == 1 && doms["accounts.google.com"]?["host-prefix"] == 1 && !"\(sum)".contains("\"v\""))
                func variants(_ u: String) -> String { GeminiExport.originalVariants(u).map { $0.url.replacingOccurrences(of: "https://lh3.googleusercontent.com", with: "") }.joined(separator: " | ") }
                check("原尺寸網址：無參數→加 =s0／=d，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX"))", variants("https://lh3.googleusercontent.com/gg/AJWX") == "/gg/AJWX=s0 | /gg/AJWX=d")
                check("原尺寸網址：=s512 換掉，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX=s512"))", variants("https://lh3.googleusercontent.com/gg/AJWX=s512") == "/gg/AJWX=s0 | /gg/AJWX=d")
                check("原尺寸網址：=w300-h400 換掉，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX=w300-h400"))", variants("https://lh3.googleusercontent.com/gg/AJWX=w300-h400") == "/gg/AJWX=s0 | /gg/AJWX=d")
                check("原尺寸網址：查詢字串照留，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX=s512?x=1&y=2"))", variants("https://lh3.googleusercontent.com/gg/AJWX=s512?x=1&y=2") == "/gg/AJWX=s0?x=1&y=2 | /gg/AJWX=d?x=1&y=2")
                check("原尺寸網址：前面的路徑段有 = 不動，只改最後一段，結果=\(variants("https://lh3.googleusercontent.com/a=b/CODE"))", variants("https://lh3.googleusercontent.com/a=b/CODE") == "/a=b/CODE=s0 | /a=b/CODE=d")
                check("原尺寸網址：非 googleusercontent 網域不改寫", GeminiExport.originalVariants("https://lh3.google.com/rd-gg/AJWX").isEmpty && GeminiExport.originalVariants("https://example.com/a/b").isEmpty)
                check("原尺寸網址：本來就是 =s0 只剩 =d", GeminiExport.originalVariants("https://lh3.googleusercontent.com/gg/AJWX=s0").map(\.name) == ["d"])
                check("原尺寸網址：路徑最後是 / 就不改寫", GeminiExport.originalVariants("https://lh3.googleusercontent.com/gg/").isEmpty)
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                   let png = rep.representation(using: .png, properties: [:]) {
                    check("像素寬高：3×2 的 PNG 讀出 \(GeminiExport.pixels(png).map { "\($0.w)×\($0.h)" } ?? "nil")", GeminiExport.pixels(png)?.w == 3 && GeminiExport.pixels(png)?.h == 2)
                }
                session.invalidateAndCancel()
                Task {
                    let s2 = GeminiExport.downloadSession(cookies: [])
                    let bad1 = await GeminiExport.download("http://lh3.google.com/x", with: s2).data, bad2 = await GeminiExport.download("https://example.com/x.png", with: s2).data
                    s2.invalidateAndCancel()
                    out.append("\(bad1 == nil && bad2 == nil ? "OK " : "NG ") download：http 或非 Google 網域直接拒絕（不連網）")
                    try? (out.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --dump-focus "秒數:檔案"：幾秒後把游標所在的元件和輸入框文字附加到檔案（測 Esc、/）
        for (i, a) in args.enumerated() where a == "--dump-focus" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let fr = self.main.window?.firstResponder
                let r = fr.map { String(describing: type(of: $0)) } ?? "nil"
                // 游標在哪一格（看第一回應者在哪段對話的格子裡）
                let owner = self.workspace.panes.first { (_, v) in (fr as? NSView).map { $0.isDescendant(of: v) } ?? false }
                let where_ = owner.flatMap { self.store.conversation($0.key)?.title } ?? "-"
                let line = "\(sec)s 游標=\(r) 格=\(where_) 目前格=\(self.store.currentWindow?.focused.flatMap { self.store.conversation($0)?.title } ?? "-") 輸入框=「\(p.inputBar.textView.string)」 停止提示=\(p.inputBar.stopHintShown)\n"
                if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
                else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        }
        // --drag-tab "秒數:第幾個分頁:拖幾個分頁寬"：按住上面的分頁往右（負數往左）拖再放開
        for (i, a) in args.enumerated() where a == "--drag-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]), let k = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let q = bar.tabCenter(n + 1) ?? bar.tabCenter(n - 1) else { return }
                let step = abs(q.x - p.x)
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...10 { pts.append((.leftMouseDragged, NSPoint(x: p.x + step * k * Double(j) / 10, y: p.y))) }
                pts.append((.leftMouseUp, NSPoint(x: p.x + step * k, y: p.y)))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
        }
        // --drag-tab-slow "秒數:第幾個分頁:拖幾個分頁寬:紀錄檔"：照真人速度慢慢拖（每 30 毫秒一步），一邊把每個分頁畫面上的 x 寫進紀錄檔
        for (i, a) in args.enumerated() where a == "--drag-tab-slow" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3)
            guard parts.count == 4, let sec = Double(parts[0]), let n = Int(parts[1]), let k = Double(parts[2]) else { continue }
            let log = String(parts[3])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let q = bar.tabCenter(n + 1) ?? bar.tabCenter(n - 1) else { return }
                let step = abs(q.x - p.x)
                var lines: [String] = []
                let t0 = ProcessInfo.processInfo.systemUptime
                func post(_ t: NSEvent.EventType, _ x: CGFloat) {
                    if let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                // 取樣計時器（常用模式：拖曳的事件迴圈裡也會跑）
                let sampler = Timer(timeInterval: 0.01, repeats: true) { _ in
                    let xs = (0..<8).compactMap { bar.tabShownX($0) }.map { String(format: "%.0f", $0) }.joined(separator: " ")
                    lines.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime - t0) + xs)
                }
                RunLoop.main.add(sampler, forMode: .common)
                post(.leftMouseDown, p.x)
                let steps = 20
                for j in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(j)) {
                        post(.leftMouseDragged, p.x + step * k * Double(j) / Double(steps)); Self.flushEvents(w)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(steps + 1)) { post(.leftMouseUp, p.x + step * k); Self.flushEvents(w) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(steps + 1) + 0.6) {
                    sampler.invalidate()
                    try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
                }
                Self.flushEvents(w)
            }
        }
        // --pull-tab "秒數:第幾個分頁:left|right|top|bottom"：把那個分頁往下拉進目前畫面第一格的那一半放開
        for (i, a) in args.enumerated() where a == "--pull-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            let edge = String(parts[2])
            // 格子還沒擺好（背景開起來有時要比較久）就每半秒再試，最多 20 次
            var tries = 0
            func attempt() {
                // edge 寫 empty：瞄準空格子的正中間
                let cv = self.main.window?.contentView
                let tv: NSView? = edge == "empty" ? Self.find(EmptyPaneView.self, in: cv) : Self.find(PaneFrame.self, in: cv)
                guard let w = self.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let f = tv, f.bounds.width > 50 else {
                    tries += 1; pullDebug("test wait \(tries)")
                    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt) }
                    return
                }
                let r = f.convert(f.bounds, to: nil)
                let q: NSPoint = ["left": NSPoint(x: r.minX + r.width * 0.15, y: r.midY), "right": NSPoint(x: r.maxX - r.width * 0.15, y: r.midY),
                                  "top": NSPoint(x: r.midX, y: r.maxY - r.height * 0.15), "bottom": NSPoint(x: r.midX, y: r.minY + r.height * 0.15)][edge] ?? NSPoint(x: r.midX, y: r.midY)
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...12 { let t = Double(j) / 12; pts.append((.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))) }
                pts.append((.leftMouseUp, q))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: attempt)
        }
        // --tear-pane "秒數:第幾格"：按住第 n 格（PaneFrame，從 0 數）的標題拖到分頁列的空白處放開（變成新分頁）
        // --swap-pane "秒數:第幾格:到第幾格:檔名開頭"：拖第幾格（由左到右）的標題到另一格中間，途中拍一張（<開頭>-mid.png），
        // 放開後把各格由左到右的聊天室名字寫進 <開頭>.txt（前後各一行）
        for (i, a) in args.enumerated() where a == "--swap-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 4)
            guard parts.count >= 4, let sec = Double(parts[0]), let n = Int(parts[1]), let m = Int(parts[2]) else { continue }
            let base = String(parts[3])
            // 第 5 段（選填）：cmd＝當成按著 ⌘ 拖（互換）；left／right／top／bottom＝放開在目標格那一邊（沒給＝正中間）。例如 "cmd" "right" "cmd,left"
            let opts = parts.count == 5 ? String(parts[4]).split(separator: ",").map(String.init) : []
            WindowHost.forceSwapDrag = opts.contains("cmd")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                func all(_ v: NSView?) -> [PaneFrame] { guard let v else { return [] }; return (v as? PaneFrame).map { [$0] } ?? v.subviews.flatMap { all($0) } }
                func order() -> String {
                    all(w.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                        .map { self.store.conversation($0.conversation)?.title ?? "?" }.joined(separator: " | ")
                }
                let fs = all(w.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                guard fs.indices.contains(n), fs.indices.contains(m) else { try? "格子不夠：\(fs.count)".write(toFile: base + ".txt", atomically: true, encoding: .utf8); return }
                var log = "前：" + order() + "\n"
                let p = fs[n].convert(NSPoint(x: fs[n].bounds.midX, y: fs[n].bounds.height - PaneFrame.headerHeight / 2), to: nil)
                var qx = fs[m].bounds.midX, qy = fs[m].bounds.midY
                if opts.contains("left") { qx = fs[m].bounds.minX + 20 }
                if opts.contains("right") { qx = fs[m].bounds.maxX - 20 }
                if opts.contains("top") { qy = fs[m].bounds.maxY - PaneFrame.headerHeight - 20 }
                if opts.contains("bottom") { qy = fs[m].bounds.minY + 20 }
                let q = fs[m].convert(NSPoint(x: qx, y: qy), to: nil)
                func post(_ t: NSEvent.EventType, _ pt: NSPoint) {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                post(.leftMouseDown, p)
                for j in 1...12 { let t = Double(j) / 12; post(.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)) }
                Self.flushEvents(w)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-mid.png"))
                    }
                    post(.leftMouseUp, q)
                    Self.flushEvents(w)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        log += "後：" + order() + "\n"
                        try? log.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--tear-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            var tries = 0
            func attempt() {
                func all(_ v: NSView?) -> [PaneFrame] { guard let v else { return [] }; return (v as? PaneFrame).map { [$0] } ?? v.subviews.flatMap { all($0) } }
                let fs = all(self.main.window?.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                guard let w = self.main.window, let bar = Self.find(TabBar.self, in: w.contentView), fs.indices.contains(n), fs[n].bounds.width > 50 else {
                    tries += 1
                    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt) }
                    return
                }
                let f = fs[n]
                let p = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.height - PaneFrame.headerHeight / 2), to: nil)
                let q = bar.emptyPoint()
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...12 { let t = Double(j) / 12; pts.append((.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))) }
                pts.append((.leftMouseUp, q))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: attempt)
        }
        // --fill-empty "秒數"：目前 Window 第一個空格子按「新增聊天室」選第一個資料夾（跳過選單）
        for (i, a) in args.enumerated() where a == "--fill-empty" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let pid = self.store.projects.first?.id else { return }
                let slot = self.store.currentWindow?.root?.leaves.first { self.store.isEmptySlot($0) }
                self.main.fillEmpty(slot, newIn: pid, group: self.store.groups.first?.id)
            }
        }
        // --codelab "秒數:check|run|context:輸出檔"：目前那格的程式碼區按檢查／執行，或把給 Claude 的那行上下文寫進檔案
        for (i, a) in args.enumerated() where a == "--codelab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            let act = String(parts[1]), out = String(parts[2])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane, let lab = p.codeLab else {
                    try? "沒有程式碼區".write(toFile: out, atomically: true, encoding: .utf8); return
                }
                lab.testAction(act) { s in try? s.write(toFile: out, atomically: true, encoding: .utf8) }
            }
        }
        // --handoff "秒數"：目前這段對話直接交接（不問）
        for (i, a) in args.enumerated() where a == "--handoff" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let c = self.store.conversation(id), let dir = self.store.project(c.projectID)?.path else { return }
                self.main.startHandoff(c, directory: dir)
            }
        }
        // --click-pane "秒數:第幾段對話"：在那段對話那格的對話區（上半部）點一下滑鼠
        for (i, a) in args.enumerated() where a == "--click-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window, n < self.store.conversations.count,
                      let v = self.workspace.panes[self.store.conversations[n].id], v.window != nil else { return }
                let pt = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.height * 0.7), to: nil)
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
        }
        // --chat-image "秒數:圖片檔"：幾秒後把圖片加到聊天框的附件（之後用 --chat-send 送出）
        for (i, a) in args.enumerated() where a == "--chat-image" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.onImages?([url], [])
            }
        }
        // --input-edited "秒數"：把輸入框所有圖片附件標成「已編輯」（橘框＋「#n 已編輯」）
        for (i, a) in args.enumerated() where a == "--input-edited" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.markAllEditedForTest()
            }
        }
        // --input-scroller "秒數:legacy|overlay"：模擬系統換捲軸樣式（接滑鼠＝legacy）
        for (i, a) in args.enumerated() where a == "--input-scroller" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.forceScrollerStyleForTest(parts[1] == "legacy" ? .legacy : .overlay)
            }
        }
        // --input-chip-dump "秒數:檔案"：把卡片列的位置寫進檔案
        for (i, a) in args.enumerated() where a == "--input-chip-dump" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.layoutSubtreeIfNeeded()
                try? (p.inputBar.chipMetricsForTest + "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --main-width "秒數:寬"：把主視窗寬度改成這個點數（測變窄時版面）
        for (i, a) in args.enumerated() where a == "--main-width" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), let wd = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window else { return }
                var f = w.frame; f.size.width = wd
                w.setFrame(f, display: true)
            }
        }
        // --chat-files "秒數:路徑,路徑…"：像在「上傳檔案」面板選了這些檔案（圖片變附件、其他插入路徑），用 --chat-js 或截圖看結果
        for (i, a) in args.enumerated() where a == "--chat-files" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let urls = parts[1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.takeFiles(urls)
                ChatSession.log?.write(Data("FILES text=\(p.inputBar.textView.string)\n".utf8))
            }
        }
        // --show-about "秒數:對話標題:圖片.png"：像按右鍵「關於…」，並把那個小視窗畫成圖
        for (i, a) in args.enumerated() where a == "--show-about" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.main.showAbout(c.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let folder = self.store.project(c.projectID)?.path ?? ""
                    let ren = ImageRenderer(content: AboutChatView(c: c, folder: folder, transcript: ContextMonitor.transcript(c, path: folder))
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    ren.scale = 2
                    if let img = ren.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: parts[2]))
                    }
                }
            }
        }
        // --drag-reset "秒數:結果檔"：模擬拖曳到一半被切走：先開接收區、再讓 App 失去前景，數視窗裡還剩幾個接收區（應該 開著>0、收掉後=0）
        for (i, a) in args.enumerated() where a == "--drag-reset" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                func count(_ v: NSView?) -> Int { guard let v else { return 0 }; return (v is DropOverlay ? 1 : 0) + v.subviews.reduce(0) { $0 + count($1) } }
                guard let root = self?.main.window?.contentView else { return }
                NotificationCenter.default.post(name: DropOverlay.began, object: nil)
                let opened = count(root)
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
                let after = count(root)
                try? "opened=\(opened) afterResign=\(after)\n".write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --radial "秒數:第幾段對話(-1＝沒有):x:y"：在螢幕座標 (x,y) 顯示 ⌥ 八宮格，「這一格」是那段對話；--radial-pick "秒數:第幾格(0＝正上方，順時針)"：選那一格；--radial-shot "秒數:檔.png"：把選單畫成圖
        for (i, a) in args.enumerated() where a == "--radial" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let n = Int(parts[1]), let x = Double(parts[2]), let y = Double(parts[3]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                RadialMenu.shared.testShow(at: NSPoint(x: x, y: y), target: self.store.conversations.indices.contains(n) ? self.store.conversations[n].id : nil)
            }
        }
        for (i, a) in args.enumerated() where a == "--radial-pick" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { RadialMenu.shared.testPick(n) }
        }
        for (i, a) in args.enumerated() where a == "--radial-shot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let img = RadialMenu.shared.testImage(), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: parts[1]))
            }
        }
        // --radial-sample "起始秒:間隔毫秒:次數:檔"：每隔一段時間把八宮格的層數、換層動畫中的 alpha／縮放寫進檔案
        for (i, a) in args.enumerated() where a == "--radial-sample" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let ms = Double(parts[1]), let n = Int(parts[2]) else { continue }
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec + Double(k) * ms / 1000) {
                    let line = String(format: "t+%.0fms ", Double(k) * ms) + RadialMenu.shared.testState() + "\n"
                    if let h = FileHandle(forWritingAtPath: parts[3]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[3], atomically: true, encoding: .utf8) }
                }
            }
        }
        // --radial-esc "秒數:結果檔"：送一個 Esc（內部合成事件）給八宮格，把送之前和之後的層數、開著與否寫進檔案
        for (i, a) in args.enumerated() where a == "--radial-esc" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                var out = "前：open=\(RadialMenu.shared.isOpen) level=\(RadialMenu.shared.level)\n"
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { NSApp.sendEvent(e) }
                out += "後：open=\(RadialMenu.shared.isOpen) level=\(RadialMenu.shared.level)\n"
                try? out.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --radial-event "秒數:結果檔"：用內部合成事件測「只按 ⌥ ＋左鍵」會不會叫出八宮格（要吃掉事件）、⌘ ⌥ ＋左鍵不會、Esc 會收掉
        for (i, a) in args.enumerated() where a == "--radial-event" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                func down(_ f: NSEvent.ModifierFlags) { if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 600, y: 400), modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(e) } }
                var out = ""
                down([.command, .option]); out += "⌘⌥ 點：開=\(RadialMenu.shared.isOpen)\n"
                down([]); out += "一般點：開=\(RadialMenu.shared.isOpen)\n"
                down(.option); out += "⌥ 點：開=\(RadialMenu.shared.isOpen)\n"
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { NSApp.sendEvent(e) }
                out += "Esc 之後：開=\(RadialMenu.shared.isOpen)\n"
                down(.option); NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
                out += "切走 App 之後：開=\(RadialMenu.shared.isOpen)\n"
                down(.option)
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) { out += "⌘ 鍵被吃掉=\(RadialMenu.shared.intercept(e))（false＝放行）；之後開=\(RadialMenu.shared.isOpen)\n" }
                try? out.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --resize "秒數:寬:高:檔名開頭"：像 Rectangle 那樣直接把主視窗設成這個大小（程式設定，不走滑鼠拖的最小寬度限制），之後把各區域的位置寫進 <開頭>.txt、整個視窗畫成 <開頭>.png
        for (i, a) in args.enumerated() where a == "--resize" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let wd = Double(parts[1]), let ht = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                var f = w.frame; f.size = NSSize(width: wd, height: ht); w.setFrame(f, display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    func walk(_ v: NSView, _ d: Int, _ out: inout String) {
                        if d > 4 { return }
                        let name = String(describing: type(of: v)); if name.contains("SplitView") || name.contains("WindowHost") || name == "NSView" || name.contains("Hosting") || name.contains("TabBar") || name.contains("PetColumn") || d < 3 {
                            out += String(repeating: "  ", count: d) + "\(name) x=\(Int(v.frame.minX)) w=\(Int(v.frame.width)) y=\(Int(v.frame.minY)) h=\(Int(v.frame.height))\n"
                        }
                        v.subviews.forEach { walk($0, d + 1, &out) }
                    }
                    var out = "window.frame=\(w.frame) contentView=\(w.contentView?.frame ?? .zero) minSize=\(w.minSize)\n"
                    if let v = w.contentView { walk(v, 0, &out) }
                    try? out.write(toFile: parts[3] + ".txt", atomically: true, encoding: .utf8)
                    if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[3] + ".png"))
                    }
                }
            }
        }
        // --detach-anim "秒數:第幾個分頁:檔名開頭"：拖出去的預覽（<開頭>-preview.png）→ 放開（獨立視窗長出來）→ 關掉（飛回分頁列），途中每隔一小段記下獨立視窗的位置、大小和透明度到 <開頭>.txt
        for (i, a) in args.enumerated() where a == "--detach-anim" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let tab = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                var log = "減少動態效果=\(Motion.reduced)\n"
                let p = NSPoint(x: 900, y: 500)
                self.main.host.testPreview(tab, at: p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let img = self.main.host.detachPreview.snapshot(), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: parts[2] + "-preview.png")) }
                    log += "預覽 frame=\(String(describing: self.main.host.detachPreview.frame))\n"
                    self.main.detachWindowTab(tab, at: p)
                    func sample(_ tag: String) { let w = self.main.detachedWindows.values.first?.window; log += "\(tag) frame=\(w?.frame ?? .zero) alpha=\(w?.alphaValue ?? -1) 可見=\(w?.isVisible ?? false)\n" }
                    for (k, t) in [0.02, 0.12, 0.5].enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + t) { sample("放開後\(k)") } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.main.detachedWindows.values.first?.window?.performClose(nil)
                        for (k, t) in [0.02, 0.12, 0.6].enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + t) { sample("關掉後\(k)") } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { log += "獨立視窗數=\(self.main.detachedWindows.count) 分頁數=\(self.store.currentSessionLayout?.windows.filter { !$0.detached }.count ?? -1)\n"; try? log.write(toFile: parts[2] + ".txt", atomically: true, encoding: .utf8) }
                    }
                }
            }
        }
        // --new-in-group "秒數:組名"：像在群組上按右鍵「在這一組開新對話」
        for (i, a) in args.enumerated() where a == "--new-in-group" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let g = self.store.groups.first(where: { $0.name == String(parts[1]) }) else { return }
                self.store.newConversation(inGroup: g.id)
            }
        }
        // --hit-test "秒數:x,y;x,y…"：幾秒後印出主視窗這些點（從左上角算，單位 pt）點下去會落在哪個 view 上
        for (i, a) in args.enumerated() where a == "--hit-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let root = w.contentView?.superview else { return }
                for pt in parts[1].split(separator: ";") {
                    let xy = pt.split(separator: ",").compactMap { Double($0) }
                    guard xy.count == 2 else { continue }
                    let p = NSPoint(x: xy[0], y: root.bounds.height - xy[1])
                    let v = root.hitTest(p)
                    print("hit \(pt) → \(v.map { String(describing: type(of: $0)) } ?? "nil")")
                }
                fflush(stdout)
            }
        }
        // --dump-panes "秒數:檔案"：附加一行「目前開著（有程序物件）的格子」的對話標題，看關掉的格子有沒有被收掉
        for (i, a) in args.enumerated() where a == "--dump-panes" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let names = self.workspace.panes.keys.compactMap { self.store.conversation($0)?.title }.sorted()
                let chats = self.workspace.panes.compactMap { id, pane -> String? in
                    guard let c = pane as? ChatPane else { return nil }
                    return "chat=\(id.uuidString) title=\(self.store.conversation(id)?.title ?? "?") hasWeb=\(c.hasWeb) webPID=\(c.webPID)"
                }.sorted()
                let webPanes = self.workspace.panes.compactMap { id, pane -> String? in
                    guard self.store.conversation(id)?.isBrowser == true else { return nil }
                    return "web=\(id.uuidString) type=\(type(of: pane))"
                }.sorted()
                let line = "t=\(parts[0]) panes=\(names)\n"
                    + "webFeaturesEnabled=\(Prefs.shared.webFeaturesEnabled) sidebarMode=\(Prefs.shared.sidebarMode) browserPanes=\(BrowserPane.all.count)\n"
                    + (chats + webPanes).map { $0 + "\n" }.joined()
                func append(_ text: String) {
                    if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile() }
                    else { try? text.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
                }
                append(line)
                // 有網頁的格子再量畫面上實際有幾則訊息、多少字（沒網頁的不叫醒它，不然量到的是重建後的）
                for (id, pane) in self.workspace.panes {
                    guard let c = pane as? ChatPane, c.hasWeb else { continue }
                    c.evaluate("JSON.stringify({turns: document.querySelectorAll('.turn').length, chars: document.body.innerText.length, bravo: (document.body.innerText.match(/BRAVO 回答/g) || []).length, perms: document.querySelectorAll('.perm.pending').length, tail: document.body.innerText.slice(-120)})") { s in
                        append("dom chat=\(id.uuidString) \(s)\n")
                    }
                }
            }
        }
        // --close-pane "秒數"：關掉目前那格（像按 × 確認之後）
        for (i, a) in args.enumerated() where a == "--close-pane" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.closePane() }
        }
        // --carry-dump "紀錄檔:輸出檔"：把一份紀錄檔整理成換模型交接的那段（只讀紀錄檔，全文檔寫到測試的 carry 資料夾）
        for (i, a) in args.enumerated() where a == "--carry-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let note = ModelCarry.note(from: URL(fileURLWithPath: String(parts[0])), session: UUID(), limit: 6000, canRead: true) ?? "nil"
            try? note.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
        }
        // --collab-dump "秒數:檔案"：協作看板讀到的往來、每一對的來回次數、提醒、待辦（讀 --state-dir 裡的 projects、collab.json）
        for (i, a) in args.enumerated() where a == "--collab-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                CollabBoardModel.shared.refresh {
                    let line = "t=\(parts[0]) open=\(CollabBoardModel.shared.open)\n" + CollabBoardModel.shared.dump()
                    if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                    else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
                }
            }
        }
        // --collab-act "秒數|動作|參數…"：像在看板上操作（測 codenv 這邊寫 collab.json）。動作：
        //   done 登記編號／approve 目標／step 目標 步驟 狀態／addgoal 標題 完成標準 步驟（\\n 分行）／addstep 目標 內容@負責人／delgoal 目標
        for (i, a) in args.enumerated() where a == "--collab-act" && i + 1 < args.count {
            let p = args[i + 1].components(separatedBy: "|")
            guard p.count >= 3, let sec = Double(p[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = CollabBoardModel.shared
                switch p[1] {
                case "done": m.editTodo(p[2], col: "done")
                case "approve": m.setGoalStatus(p[2], "active")
                case "step" where p.count >= 5: m.setStep(goal: p[2], step: p[3], state: p[4])
                case "addgoal" where p.count >= 5: m.addGoal(title: p[2], done: p[3], steps: p[4].replacingOccurrences(of: "\\n", with: "\n"))
                case "addstep" where p.count >= 4: m.addStep(goal: p[2], line: p[3])
                case "delgoal": m.deleteGoal(p[2])
                case "delfinding": m.deleteFinding(p[2])                              // 刪一筆發現：delfinding|編號
                case "tab": m.tab = p[2]                                              // 切分頁：tab|goals／messages／findings
                case "collapse": m.toggleCollapsed(p[2])                            // 收起／展開：collapse|目標
                case "autoapprove": m.setAutoApprove(p[2] == "true")                 // autoapprove|true／false
                case "cancel" where p.count >= 4: m.cancelAgyStep(goal: p[2], step: p[3])   // 終止：cancel|目標|步驟
                case "notices" where p.count >= 4:      // 寫出某個聊天室（標題）等著收的提示，並拿走：notices|聊天室標題|檔案
                    let text = m.convByName[p[2]].flatMap { CollabBoardModel.takeNotices(for: $0) } ?? "（沒有）"
                    try? text.write(toFile: p[3], atomically: true, encoding: .utf8)
                case "setowner" where p.count >= 5: m.setOwner(goal: p[2], step: p[3], owner: p[4])   // 改負責人：setowner|目標|步驟|名字
                case "manualprompt" where p.count >= 5:   // 手動步驟的 prompt 寫進檔案：manualprompt|目標|步驟|檔案
                    if let st = m.goals.first(where: { $0.id == p[2] })?.steps.first(where: { $0.id == p[3] }) { try? CollabBoardModel.manualPrompt(st).write(toFile: p[4], atomically: true, encoding: .utf8) }
                case "manualreturn" where p.count >= 5:   // 交回：manualreturn|目標|步驟|回答（\\n 分行）；結果寫進 state-dir/manual-return.txt
                    let ok = m.returnManual(goal: p[2], step: p[3], text: p[4].replacingOccurrences(of: "\\n", with: "\n"))
                    let line = "manualreturn \(p[3]) → \(ok)\n"
                    let f = URL(fileURLWithPath: CollabBoardModel.todoFile.deletingLastPathComponent().path).appendingPathComponent("manual-return.txt")
                    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
                default: break
                }
            }
        }
        // --rename "秒數:新名字"：把目前選的對話改名（像側欄右鍵重新命名）
        for (i, a) in args.enumerated() where a == "--rename" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected else { return }
                self.store.rename(id, to: String(parts[1]), byUser: true)
            }
        }
        // --schedule-put "秒數|第幾段對話|頻率|時間（逗號）|要送的話|沒開著時|每隔幾分鐘"：新增一個排程（下一次照 --fake-now 的「現在」算）
        for (i, a) in args.enumerated() where a == "--schedule-put" && i + 1 < args.count {
            let p = args[i + 1].components(separatedBy: "|")
            guard p.count >= 6, let sec = Double(p[0]), let n = Int(p[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, n < self.store.conversations.count else { return }
                var sc = WakeSchedule(conversation: self.store.conversations[n].id, text: p[4])
                sc.frequency = p[2]
                sc.times = p[3].components(separatedBy: ",")
                sc.whenClosed = p[5]
                if p.count > 6, let m = Int(p[6]) { sc.intervalMinutes = m }
                ScheduleStore.shared.put(sc)
            }
        }
        // --schedule-sheet "秒數:第幾段對話"：打開那段對話的「排程…」小視窗（像在側欄右鍵）
        for (i, a) in args.enumerated() where a == "--schedule-sheet" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, Int(parts[1]) < self.store.conversations.count else { return }
                self.main.showSchedule(self.store.conversations[Int(parts[1])].id)
            }
        }
        // --schedule-dump "秒數:檔案"：附加每個排程的下一次、待送、最近幾次結果
        for (i, a) in args.enumerated() where a == "--schedule-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let line = "t=\(parts[0]) now=\(ISO8601DateFormatter.local.string(from: ScheduleStore.now()))\n" + ScheduleStore.shared.dump()
                if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
            }
        }
        // --right-tab "秒數:視窗|檔案|Git|歷史|看板"：打開右欄並切到那個分頁（會把測試實例的右欄開起來）
        for (i, a) in args.enumerated() where a == "--right-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), let tab = RightTab.named(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.showRightPanel(tab: tab) }
        }
        // --rp-op "秒數:操作:參數…"：聊天室資訊（選取／i／資訊卡）的測試掛鉤，只在測試實例（有 --state-dir）生效
        //   select:<標題>（只改選取，不經過點擊）、click:x:y（用 NSApp.postEvent 在主視窗內容區的座標點一下，左上為原點）、key:i（把 i 鍵送到主視窗）、
        //   info:<標題>（直接開表單）、topic:<標題>:<說明>（等於在表單按儲存說明）、card:<標題>（走滑過 2 秒的計時流程）、card-end:<標題>、
        //   delay:<秒>（改資訊卡等待時間）、dump:<檔案>（選取、表單、資訊卡狀態 JSON）、form-snapshot:<檔案.png>（表單是 sheet，拍它的視窗）
        for (i, a) in args.enumerated() where a == "--rp-op" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let win = self.main.window else { return }
                let m = RightPanelModel.shared
                let arg = parts.count > 2 ? parts[2] : ""
                let cid = { (t: String) in self.store.conversations.first(where: { $0.title == t })?.id }
                func send(_ type: NSEvent.EventType, _ pt: NSPoint) {
                    let h = win.contentView?.bounds.height ?? 0
                    let wp = win.contentView?.convert(NSPoint(x: pt.x, y: h - pt.y), to: nil) ?? pt
                    if let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                switch parts[1] {
                case "select": m.selectedChat = cid(arg)
                case "focus": self.main.focusRightPanelForTest()
                case "click":
                    let xy = arg.split(separator: ":").compactMap { Double($0) }
                    guard xy.count == 2 else { return }
                    let pt = NSPoint(x: xy[0], y: xy[1])
                    if let cv = win.contentView { EventLog.log("測試", "rp click bounds=\(cv.bounds) flipped=\(cv.isFlipped) hit=\(String(describing: cv.hitTest(cv.convert(NSPoint(x: pt.x, y: cv.bounds.height - pt.y), from: nil)).map { type(of: $0) })) key=\(win.isKeyWindow)") }
                    send(.mouseMoved, pt); send(.leftMouseDown, pt); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { send(.leftMouseUp, pt) }
                case "key":
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: arg, charactersIgnoringModifiers: arg, isARepeat: false, keyCode: 34) { NSApp.postEvent(e, atStart: false) }
                case "info": if let id = cid(arg) { m.selectedChat = id; m.infoChat = id }
                case "topic": // 標題:說明
                    let kv = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    if kv.count == 2, let id = cid(kv[0]) { self.store.setTopic(id, kv[1], byUser: true) }
                case "card": if let id = cid(arg) { ChatInfoCard.shared.hoverBegan(id, store: self.store, workspace: self.workspace, window: win) }
                case "card-end": if let id = cid(arg) { ChatInfoCard.shared.hoverEnded(id) }
                case "delay": ChatInfoCard.delay = Double(arg) ?? 2
                case "dump":
                    let o: [String: Any] = ["selected": m.selectedChat.flatMap { self.store.conversation($0)?.title } ?? NSNull(),
                                            "infoOpen": m.infoChat != nil, "cardFor": ChatInfoCard.shared.shownFor.flatMap { self.store.conversation($0)?.title } ?? NSNull(),
                                            "firstResponder": String(describing: win.firstResponder.map { type(of: $0) }),
                                            "topics": self.store.conversations.reduce(into: [String: Any]()) { $0[$1.title] = $1.topic ?? NSNull() },
                                            "topicByCommander": self.store.conversations.reduce(into: [String: Any]()) { $0[$1.title] = $1.topicByCommander ?? NSNull() }]
                    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: arg), options: .atomic) }
                case "form-snapshot":
                    let sheet = win.attachedSheet ?? NSApp.windows.first(where: { $0.sheetParent === win })
                    guard let v = sheet?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                default: break
                }
            }
        }
        // --store-op "秒數:summon:<聊天室標題>"：像在右欄按「叫出來」（對目前 Session）。也支援 "秒數:focus-window:<第幾個 Window，從 1 算>"
        for (i, a) in args.enumerated() where a == "--store-op" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                switch parts[1] {
                case "summon":
                    guard let c = self.store.conversations.first(where: { $0.title == parts[2] }), let sid = self.store.currentSessionLayout?.id else { return }
                    self.store.summonConversation(c.id, inSession: sid)
                case "focus-window":
                    guard let n = Int(parts[2]), let s = self.store.currentSessionLayout, n >= 1, n <= s.windows.count else { return }
                    self.store.focusWindowFromPanel(s.windows[n - 1].id)
                case "history":
                    RightPanelModel.shared.history.search(parts[2], targets: RPData.historyTargets(self.store), convs: RPData.historyConvs(self.store))
                case "fsearch":   // "name:<字>" 或 "content:<字>"
                    let kv = parts[2].split(separator: ":", maxSplits: 1).map(String.init)
                    if kv.count == 2 { RightPanelModel.shared.search.search(kv[1], content: kv[0] == "content", root: RightPanelModel.shared.projectPath) }
                case "git-select":
                    if let c = RightPanelModel.shared.git.changes.first(where: { $0.path == parts[2] }) { RightPanelModel.shared.git.select(c) }
                case "select-session":
                    if let s = self.store.sessions.first(where: { $0.name == parts[2] }) { self.store.selectSession(s.id) }
                default: break
                }
            }
        }
        // --dump-right "秒數:檔案"：輸出右欄目前分頁與清單內容（JSON）
        for (i, a) in args.enumerated() where a == "--dump-right" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let m = RightPanelModel.shared
                m.syncProject(self.store.rightPanelProject()?.path)
                let o = m.dump(store: self.store, workspace: self.workspace)
                if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: parts[1]), options: .atomic) }
            }
        }
        // --graph-op "秒數:操作:參數"：關聯圖測試掛鉤（只在 --state-dir 測試實例生效）
        //   fake:<區數>:<聊天室數>（在目前總指揮底下造假的區與聊天室，區會巢狀、幾個設成工作中／等你）、mode:graph|list（右欄顯示方式）、
        //   panel:open|close（F6 面板）、dump:<檔>（關聯圖節點／位置／計時器 JSON）、select:<標題>、area:add|move…不在這裡（用 codenv-todo）
        for (i, a) in args.enumerated() where a == "--graph-op" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let arg = parts.count > 2 ? parts[2] : ""
                switch parts[1] {
                case "fake":
                    let nums = arg.split(separator: ":").compactMap { Int($0) }
                    guard nums.count == 2, let s = self.store.currentSessionLayout, let root = self.store.areaRoot(s),
                          let pid = self.store.projects.first?.id else { return }
                    var areas: [UUID] = []
                    for k in 0..<nums[0] {
                        let parent = (k >= 3 && k % 2 == 1) ? areas[k / 3 - 1 + 0] : root
                        areas.append(self.store.addGroup(named: "假區\(k + 1)", parent: parent).id)
                    }
                    let keep = self.store.selectedProject
                    for k in 0..<nums[1] {
                        let c = self.store.createConversation(in: pid)
                        self.store.selectedProject = keep
                        self.store.move(c.id, toGroup: areas.isEmpty || k % 7 == 0 ? root : areas[k % areas.count])
                        self.store.rename(c.id, to: "假聊天室\(k + 1)", byUser: false)
                        if k % 9 == 0 { self.store.status[c.id] = .working }
                        else if k % 23 == 1 { self.store.status[c.id] = .waiting }
                    }
                case "click", "move", "rclick":    // 標題：在節點中心送滑鼠事件（移動後立刻按，不等 hover）
                    guard let win = self.main.window, let g = self.main.graphPanel.graphView ?? ChatGraphView.rightInstance, let wp = g.windowPoint(title: arg) else { return }
                    func post(_ type: NSEvent.EventType) {
                        if let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                    }
                    post(.mouseMoved)
                    if parts[1] == "click" { post(.leftMouseDown); DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { post(.leftMouseUp) } }
                    if parts[1] == "rclick" { post(.rightMouseDown); DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { post(.rightMouseUp) } }
                case "mode": RightPanelModel.shared.chatGraph = arg == "graph"
                case "panel": if arg == "open" { self.main.graphPanel.show() } else { self.main.graphPanel.hide() }
                case "select":
                    RightPanelModel.shared.selectedChat = self.store.conversations.first { $0.title == arg }?.id
                case "dump":
                    let gp = self.main.graphPanel.graphView
                    var o: [String: Any] = ["panelOpen": self.main.graphPanel.isOpen, "mode": RightPanelModel.shared.chatGraph ? "graph" : "list",
                                            "panel": gp?.dump() ?? NSNull(), "right": ChatGraphView.rightInstance?.dump() ?? NSNull()]
                    o["firstResponder"] = String(describing: self.main.window?.firstResponder.map { type(of: $0) })
                    if let win = self.main.window, let cv = win.contentView, let g = self.main.graphPanel.graphView, let wp = g.windowPoint(title: "codenv_2") {
                        o["hitTest"] = String(describing: cv.hitTest(cv.superview?.convert(wp, from: nil) ?? wp).map { type(of: $0) })
                        o["isKey"] = win.isKeyWindow
                    }
                    o["sheet"] = self.main.window?.attachedSheet.map { String(describing: type(of: $0)) } ?? "none"
                    o["selected"] = RightPanelModel.shared.selectedChat.flatMap { self.store.conversation($0)?.title } ?? NSNull()
                    o["infoChat"] = RightPanelModel.shared.infoChat.flatMap { self.store.conversation($0)?.title } ?? NSNull()
                    o["areas"] = self.store.currentSessionLayout.map { s in self.store.areaNodes(s).map { self.store.areaPath($0.group.id, in: s) } } ?? []
                    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: arg), options: .atomic) }
                default: break
                }
            }
        }
        // --collab-open "秒數"：打開協作看板（像按最左邊的協作圖示）
        for (i, a) in args.enumerated() where a == "--collab-open" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { CollabBoardModel.shared.open = true }
        }
        // --area "秒數:home|codelab"：像點側欄最左邊的圖示換區
        for (i, a) in args.enumerated() where a == "--area" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.switchArea(String(parts[1])) }
        }
        // --dump-layout "秒數:檔案"：附加一行目前在哪一區、看的是哪個 Session，每個 Session（區）裡各 Window 擺了哪些對話
        for (i, a) in args.enumerated() where a == "--dump-layout" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let t = { (id: UUID) in self.store.conversation(id)?.title ?? "空" }
                let all = self.store.sessions.map { s in "\(s.name)(\(s.area ?? "home"))=" + s.windows.map { w in (w.detached ? "↗[" : "[") + (w.root?.leaves.map(t) ?? []).joined(separator: ",") + "]" }.joined() }
                let line = "t=\(parts[0]) 左欄收=\(self.main.sidebarCollapsed) 右欄=\(PetSlot.enabled) 協作=\(CollabBoardModel.shared.open) area=\(self.store.area) 看=\(self.store.currentSessionLayout?.name ?? "nil") 獨立視窗=\(self.main.detachedWindows.values.map { $0.window.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil" }) 主視窗現=\(self.store.scoped(nil) { self.store.windowIndex ?? -1 }) scope=\(self.store.scope != nil) 選=\(self.store.selected.map(t) ?? "nil") | " + all.joined(separator: " ") + "\n"
                if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
            }
        }
        // --dump-commanders "秒數:檔案"：僅 --state-dir 的測試實例生效，輸出所有區域 Session 的總指揮關聯與遞迴涵蓋數
        for (i, a) in args.enumerated() where a == "--dump-commanders" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                func field<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
                let sessions: [[String: Any]] = st.sessions.map { session in
                    ["id": session.id.uuidString, "name": session.name, "area": session.area ?? "home",
                     "groups": field(session.groups.map { $0.map { st.group($0)?.name ?? $0.uuidString } }),
                     "groupIDs": field(session.groups.map { $0.map(\.uuidString) }),
                     "chief": field(session.chief.flatMap { st.conversation($0)?.title }),
                     "chiefID": field(session.chief?.uuidString), "windowCount": session.windows.count,
                     "conversationCount": st.conversations(inCommander: session).count]
                }
                let object: [String: Any] = ["area": st.area, "sidebarMode": Prefs.shared.sidebarMode,
                    "currentSession": field(st.currentSession?.uuidString),
                    "currentSessionName": field(st.sessions.first { $0.id == st.currentSession }?.name), "sessions": sessions]
                do {
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
                } catch { EventLog.log(L("測試"), L("總指揮狀態輸出失敗：\(error.localizedDescription)")) }
            }
        }
        // --move-folder "秒數:對話標題:新資料夾"：像在對話上按右鍵「換工作資料夾…」（不問，直接搬）
        for (i, a) in args.enumerated() where a == "--move-folder" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == String(parts[1]) }) else { return }
                self.main.moveConversation(c.id, to: String(parts[2]))
            }
        }
        // --chat-js "秒數:JS"：幾秒後在聊天畫面裡跑一段 JS（例如點按鈕），結果附加到 --chat-log
        for (i, a) in args.enumerated() where a == "--chat-js" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let code = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.evaluate(code) { r in ChatSession.log?.write(Data("JS \(code.prefix(60)) => \(r.prefix(300))\n".utf8)) }
            }
        }
        // --web-drag "秒數:x0:y0:x1:y1:按住秒數"：在主視窗第一個聊天網頁區按下左鍵（比例座標，左上角 0,0、右下角 1,1），
        // 慢慢拖到 (x1,y1)（可以超出 0～1＝拖到網頁外面，例如 1.05＝底下的輸入框），停著按住幾秒再放開（測拖曳選取碰到邊緣會不會自動捲）
        for (i, a) in args.enumerated() where a == "--web-drag" && i + 1 < args.count {
            let v = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard v.count == 6 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + v[0]) { [weak self] in
                guard let w = self?.main.window, let web = Self.find(DropWebView.self, in: w.contentView) else { return }
                func at(_ fx: Double, _ fy: Double) -> NSPoint {
                    let b = web.bounds
                    return web.convert(NSPoint(x: b.width * fx, y: web.isFlipped ? b.height * fy : b.height * (1 - fy)), to: nil)
                }
                // 直接交給網頁（背景測試視窗不是 key，postEvent 進不到 WKWebView）
                func post(_ t: NSEvent.EventType, _ pt: NSPoint) {
                    guard let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    switch t { case .leftMouseDown: web.mouseDown(with: e); case .leftMouseUp: web.mouseUp(with: e); default: web.mouseDragged(with: e) }
                }
                DropWebView.testPressed = true      // 模擬事件讀不到系統按鍵狀態
                post(.leftMouseDown, at(v[1], v[2]))
                for j in 1...15 {   // 照真人速度：每 40 毫秒一步
                    let t = Double(j) / 15
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(j)) { post(.leftMouseDragged, at(v[1] + (v[3] - v[1]) * t, v[2] + (v[4] - v[2]) * t)) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + v[5]) { post(.leftMouseUp, at(v[3], v[4])); DropWebView.testPressed = nil }
            }
        }
        // --web-move "秒數:x:y"：滑鼠移到主視窗第一個聊天網頁區的 (x,y)（比例座標，左上 0,0），沒按鍵（測自動捲之後命中位置有沒有偏）
        for (i, a) in args.enumerated() where a == "--web-move" && i + 1 < args.count {
            let v = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard v.count == 3 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + v[0]) { [weak self] in
                guard let w = self?.main.window, let web = Self.find(DropWebView.self, in: w.contentView) else { return }
                let b = web.bounds
                let pt = web.convert(NSPoint(x: b.width * v[1], y: web.isFlipped ? b.height * v[2] : b.height * (1 - v[2])), to: nil)
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { web.mouseMoved(with: e) }
            }
        }
        // --chat-respawn "秒數"：目前那段聊天室的 claude 程序 terminate 之後馬上重開（測舊程序晚到的輸出不會混進新程序）
        for (i, a) in args.enumerated() where a == "--chat-respawn" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.terminate()
                _ = p.session.start()
            }
        }
        // --chat-model "秒數:模型"：幾秒後像從選單換模型（haiku、fable…；default＝預設）
        for (i, a) in args.enumerated() where a == "--chat-model" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.applyModel(v)
                p.onModelChange?(v == "default" ? nil : v)
            }
        }
        // --keys "秒數:按鍵 按鍵 …"：幾秒後模擬按鍵（走跟真的按鍵一樣的路），例如 "3:C-a | C-a h"
        for (i, a) in args.enumerated() where a == "--keys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window else { return }
                for (n, t) in tokens.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) }
                }
            }
        }
        // --dbrowser-eval "秒數:JS"：在（第一個）獨立視窗裡的瀏覽器格跑一段 JS，結果寫進 state-dir/browser-test.log
        for (i, a) in args.enumerated() where a == "--dbrowser-eval" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.store.sessions.flatMap(\.windows).first(where: { $0.detached }),
                      let b = (w.root?.leaves ?? []).compactMap({ self.workspace.panes[$0] as? BrowserPane }).first else { return }
                let logURL = self.store.directory.appendingPathComponent("browser-test.log")
                b.webView.evaluateJavaScript(parts[1]) { r, e in
                    let d = Data("獨立視窗的瀏覽器 eval → \(r.map { "\($0)" } ?? "nil")\(e.map { " 錯誤：\($0.localizedDescription)" } ?? "")\n".utf8)
                    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: logURL) }
                }
            }
        }
        // --dkeys "秒數:按鍵 …"：同 --keys，但丟給（第一個）獨立視窗
        for (i, a) in args.enumerated() where a == "--dkeys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.detachedWindows.values.first?.window else { return }
                for (n, t) in tokens.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) } }
            }
        }
        // --place "秒數:第幾段對話:left|right|top|bottom|center"：像從側欄把對話拖到目前那格的某一邊
        for (i, a) in args.enumerated() where a == "--place" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, n < self.store.conversations.count, let target = self.store.currentWindow?.focused else { return }
                let conv = self.store.conversations[n].id
                let edge: DropOverlay.Edge? = ["left": .left, "right": .right, "top": .top, "bottom": .bottom][parts[2]] ?? nil
                self.store.place(conv, near: target, edge: edge)
            }
        }
        // --chat-effort "秒數:low|medium|high|xhigh|max"：像從選單換思考強度
        for (i, a) in args.enumerated() where a == "--chat-effort" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.applyEffort(v)
                p.onEffortChange?(v)
            }
        }
        // --import-live "秒數"：像打開「自動加入」那樣，把正在跑的對話抓進來
        for (i, a) in args.enumerated() where a == "--import-live" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                ClaudeSessions.importLive(into: self.store)
            }
        }
        // --open-session "秒數:Claude 對話編號開頭"：打開那段對話
        for (i, a) in args.enumerated() where a == "--open-session" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let prefix = String(parts[1]).uppercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.claudeSession.uuidString.hasPrefix(prefix) }) else { return }
                self.store.open(c.id)
            }
        }
        // --chat-fork "秒數"：像按「在這裡接手（複製一份）」
        for (i, a) in args.enumerated() where a == "--chat-fork" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.forkFrom = p.session.claudeSession
            }
        }
        // --chat-drop "秒數:檔案"：像把這個檔案拖進聊天畫面（走拖放收件那段）
        for (i, a) in args.enumerated() where a == "--chat-drop" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1])) as NSURL
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let pb = NSPasteboard(name: NSPasteboard.Name("AIWorkbenchTest-\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects([url])
                _ = p.inputBar.takeDrop(pb)
                pb.releaseGlobally()
            }
        }
        // --model-list "秒數"：面板開著時切到模型清單那頁
        for (i, a) in args.enumerated() where a == "--model-list" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.testShowModelList()
            }
        }
        // --render-panel "秒數:檔案.png"：把思考強度面板直接畫成圖片（不用讓 App 跑到前面）
        // --shot-models "秒數:檔名開頭"：打開目前聊天室的模型面板、換到模型清單，每個分頁拍一張（＋列出內容的 .txt）
        for (i, a) in args.enumerated() where a == "--shot-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let m = ModelPanelModel.last else { return }
                    m.showingModels = true; m.onSizeChange?()
                    for (n, t) in m.tabs.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(n) * 0.6) {
                            m.tab = t; m.onSizeChange?()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                let list = m.shownSections.map { $0.map { $0.id + " | " + $0.shownTitle + ($0.via.map { " (\($0))" } ?? "") + ($0.checked ? " ✓" : "") }.joined(separator: "\n") }.joined(separator: "\n---\n")
                                try? "分頁：\(m.tabs.map(\.title))\n\(list)\n".write(toFile: "\(base)-\(t.rawValue).txt", atomically: true, encoding: .utf8)
                                guard let w = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }), let v = w.contentView,
                                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                                v.cacheDisplay(in: v.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(t.rawValue).png"))
                            }
                        }
                    }
                }
            }
        }
        // --anim-models "秒數:檔名開頭"：打開模型清單，從 Claude 換到 Gemini 再換回來，動畫途中每 40 毫秒記一次面板位置並拍照（查換頁跳動）
        for (i, a) in args.enumerated() where a == "--anim-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
                var log = ""
                func shot(_ tag: String) {
                    guard let w = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }), let v = w.contentView else { return }
                    log += "\(tag) frame=\(w.frame)\n"
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(tag).png"))
                    }
                    try? log.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let m = ModelPanelModel.last else { return }
                    m.tab = .claude; m.showingModels = true; m.onSizeChange?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        shot("a0")
                        withAnimation(.easeInOut(duration: 0.18)) { m.tab = .gemini }
                        m.onSizeChange?()
                        for k in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.04) { shot("a\(k)") } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            shot("b0")
                            withAnimation(.easeInOut(duration: 0.18)) { m.tab = .claude }
                            m.onSizeChange?()
                            for k in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.04) { shot("b\(k)") } }
                        }
                    }
                }
            }
        }
        // --usage-page "秒數:檔名開頭"：等用量查完，把右側欄會列的（目前分頁用到的組）寫進 <開頭>.txt、拍整個視窗，
        // 再打開置中的完整用量頁拍一張（<開頭>-page.png）
        for (i, a) in args.enumerated() where a == "--usage-page" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                let m = UsageMonitor.shared
                var out = "目前分頁的組：" + self.store.usagePoolsInCurrentWindow.map { $0.pool.rawValue + ($0.argon ? "+argon" : "") }.joined(separator: ", ") + "\n"
                for p in self.store.usagePoolsInCurrentWindow { for r in m.rows(p.pool, argon: p.argon) { out += "  側欄 \(p.pool.rawValue) | \(r.label) | \(r.bucket.remaining)% | \(r.bucket.resets)\n" } }
                for p in UsagePool.allCases { for r in m.rows(p) { out += "  全部 \(p.rawValue) | \(r.label) | \(r.bucket.remaining)%\n" }; if let n = m.note(p) { out += "  附註 \(p.rawValue) | \(n)\n" } }
                try? out.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-window.png"))
                }
                UsageSheet.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let p = UsageSheet.current, let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-page.png"))
                    try? (out + "完整頁大小 \(p.frame.size)，主視窗 \(w.frame.size)，置中差 \(Int(p.frame.midX - w.frame.midX)),\(Int(p.frame.midY - w.frame.midY))\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                }
            }
        }
        // --render-activity "秒數:檔案.png"：把右欄「正在跑」那一塊（目前選的對話）畫成圖（背景測試時右欄被看板佔著、也畫不清楚）。搭 --chat-claude 的假 claude 讓它有東西在跑
        for (i, a) in args.enumerated() where a == "--render-activity" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let root = ZStack { Color(white: 0.13); ActivityBlock(store: self.store).padding(12) }
                    .frame(width: 300).environment(\.uiScale, 1).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(origin: .zero, size: NSSize(width: 300, height: host.fittingSize.height))
                host.layoutSubtreeIfNeeded()
                host.appearance = NSAppearance(named: .darkAqua)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --render-usage "秒數:檔案.png:寬:高"：把整個右欄（UsagePanel，含捲動與撐滿高度）用指定的寬高畫成圖，測窄欄用；搭 CODENV_FAKE_RUNNING
        for (i, a) in args.enumerated() where a == "--render-usage" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let w = Double(parts[2]), let h = Double(parts[3]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let root = ZStack { Color(white: 0.13); UsagePanel(m: UsageMonitor.shared, store: self.store) }
                    .frame(width: w, height: h).environment(\.uiScale, 1).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: w, height: h)
                host.appearance = NSAppearance(named: .darkAqua)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                }
            }
        }
        // --render-usage-full "秒數:檔案.png"：把用量詳細頁（點「用量剩餘 >」開的那頁，含 Codex 重置券過期時間）畫成圖；搭 CODENV_USAGE_FAKE=1
        for (i, a) in args.enumerated() where a == "--render-usage-full" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let w = UsageFullPage.width(columns: 3, scale: 1), h: CGFloat = 700
                let root = UsageFullPage(m: UsageMonitor.shared, scroll: false).frame(width: w, height: h)
                    .background(Color(white: 0.13)).environment(\.uiScale, 1).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: w, height: h)
                host.appearance = NSAppearance(named: .darkAqua)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                }
            }
        }
        // --render-models "秒數:檔名開頭"：用假資料畫模型清單的每個分頁（<開頭>-claude.png、-gemini.png、-local.png）
        for (i, a) in args.enumerated() where a == "--render-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = ModelPanelModel()
                m.modelName = "Opus 5.5"; m.levels = Effort.order; m.defaultEffort = "high"; m.showingModels = true
                let r = { (id: String, t: String, c: Bool) in ModelRow(id: id, title: t, tip: "", checked: c) }
                m.sections = [[r("opus", "Opus 5.5", true), r("claude-opus-5", "Opus 5", false)], [r("sonnet", "Sonnet 5.5", false)],
                              [r("agy:gemini-4-argon-high", "Gemini 4 Argon", false), r("agy:gemini-3.8-flash-high", "Gemini 3.8 Flash", false),
                               r("agy:claude-opus-5-5-high", "Claude Opus 5.5", false), r("agy:claude-sonnet-5-5-high", "Claude Sonnet 5.5", false)],
                              [r("codex:gpt-6-luna", "GPT-6 Luna", false), r("codex:gpt-5.6-terra", "GPT-5.6 Terra", false)],
                              [r("copilot:auto", "Auto", false)],
                              [r("local:x", "LFM2.5", false)]]
                for t in ModelTab.allCases {
                    m.tab = t
                    let list = m.shownSections.map { $0.map { $0.shownTitle + ($0.via.map { " (\($0))" } ?? "") + ($0.checked ? " ✓" : "") }.joined(separator: "\n") }.joined(separator: "\n---\n")
                    try? "分頁：\(m.tabs.map(\.title))\n\(list)\n".write(toFile: "\(base)-\(t.rawValue).txt", atomically: true, encoding: .utf8)
                    let ren = ImageRenderer(content: ModelPanel(m: m).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    ren.scale = 2
                    if let img = ren.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(base)-\(t.rawValue).png"))
                    }
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--render-panel" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = ModelPanelModel()
                m.modelName = "Opus 5.5"; m.levels = Effort.order; m.defaultEffort = "high"
                let r = ImageRenderer(content: ModelPanel(m: m).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --render-sessions "秒數:檔案.png"：把 Session 面板畫成圖片（不真的打開，不會蓋到畫面上）
        for (i, a) in args.enumerated() where a == "--render-sessions" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let m = SessionPanelModel()
                m.rows = self.main.sessionRows(); m.canClose = self.store.sessions.count > 1; m.keyIndex = 2
                let v = NSHostingView(rootView: SessionPanel(m: m))
                v.frame = NSRect(origin: .zero, size: v.fittingSize)
                v.layoutSubtreeIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --model-panel "秒數"：按右下角的模型按鈕
        for (i, a) in args.enumerated() where a == "--model-panel" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
            }
        }
        // --input-probe "秒數:檔案"：輸入框塞 13 行、最後一行是換行的草稿，問文字框「點最後那條空行的中間／下緣留白／左緣留白，游標會到第幾個字」，
        // 並記最後空行有沒有在可見範圍內（測「最後一行點不到」，不用動滑鼠）
        for (i, a) in args.enumerated() where a == "--input-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            // 檔案前面可以加「行數@」，例如 3@/tmp/x.txt（預設 13 行）
            var path = String(parts[1]), lines = 13
            if let at = path.firstIndex(of: "@"), let n = Int(path[..<at]) { lines = n; path = String(path[path.index(after: at)...]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { try? "沒有聊天格".write(toFile: path, atomically: true, encoding: .utf8); return }
                // 直接放進草稿（像還原草稿、訊息沒送到放回輸入框）：這條路捲動不會自己跟上
                p.inputBar.setDraft((1...lines).map { "第\($0)行中文字 abc" }.joined(separator: "\n") + "\n")
                p.inputBar.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let tv = p.inputBar.textView
                    guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
                    lm.ensureLayout(for: tc)
                    let extra = lm.extraLineFragmentRect, o = tv.textContainerOrigin
                    let len = (tv.string as NSString).length
                    let mid = NSPoint(x: o.x + 20, y: o.y + extra.midY)
                    let below = NSPoint(x: o.x + 20, y: o.y + extra.maxY + 3)
                    let left = NSPoint(x: 1, y: o.y + extra.midY)
                    let extraTV = extra.offsetBy(dx: o.x, dy: o.y)
                    let vis = tv.enclosingScrollView?.contentView.bounds ?? .zero
                    let out = "len=\(len) extra=\(extraTV) visible=\(vis) 看得到最後空行=\(vis.contains(extraTV))\n" +
                        "點中間→\(tv.characterIndexForInsertion(at: mid)) 點下緣留白→\(tv.characterIndexForInsertion(at: below)) 點左緣留白→\(tv.characterIndexForInsertion(at: left))\n" +
                        "textView.frame=\(tv.frame) scroll.frame=\(tv.enclosingScrollView?.frame ?? .zero)\n" +
                        // 真的點下去會落到哪個 view：從視窗最上層 hitTest（滑鼠事件就是這樣找收件人）
                        [("最後空行中間", mid), ("下緣留白", below), ("空行下方 10 點", NSPoint(x: o.x + 20, y: o.y + extra.maxY + 10)), ("空行下方 18 點", NSPoint(x: o.x + 20, y: o.y + extra.maxY + 18))].map { name, pt -> String in
                            let w = tv.convert(pt, to: nil)
                            let hit = tv.window?.contentView?.superview?.hitTest(w) ?? tv.window?.contentView?.hitTest(w)
                            return "\(name)→\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
                        }.joined(separator: "  ") + "\n" +
                        // 游標先放在第 5 個字，再像點在空行下方 10 點那樣點一下框：游標應該跑到最後
                        { () -> String in
                            tv.setSelectedRange(NSRange(location: 5, length: 0))
                            p.inputBar.clickBesideText(atWindowPoint: tv.convert(NSPoint(x: o.x + 20, y: o.y + extra.maxY + 10), to: nil))
                            let a = tv.selectedRange().location
                            tv.setSelectedRange(NSRange(location: 5, length: 0))
                            p.inputBar.clickBesideText(atWindowPoint: tv.convert(NSPoint(x: o.x + 400, y: o.y + extra.maxY + 18), to: nil))
                            return "點框下方空白（左）→游標 \(a)  點框下方空白（右邊遠處）→游標 \(tv.selectedRange().location)  焦點在文字框=\(tv.window?.firstResponder === tv)\n"
                        }()
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --codelab-recovery-probe "秒數:edit|inspect|restore|discard|save|close:原始檔:輸出檔"
        // 只在 --state-dir 啟用：保留一個沒有視窗的 CodeLab，測真正的 JS 防抖、復原與清除。
        for (i, a) in args.enumerated() where a == "--codelab-recovery-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]),
                  ["edit", "inspect", "restore", "discard", "save", "close"].contains(parts[1]),
                  parts[2].hasPrefix("/"), parts[3].hasPrefix("/") else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let lab = CodeLabView(directory: (parts[2] as NSString).deletingLastPathComponent,
                                      key: "recovery-probe", theme: self.appearance.theme)
                self.recoveryProbeLabs.append(lab)
                lab.recoveryProbe(path: parts[2], action: parts[1]) { output in
                    print(output)
                    try? output.write(toFile: parts[3], atomically: true, encoding: .utf8)
                }
            }
        }
        // --outbox-probe "秒數:seed|seed-delivered|recover|dump:檔案"：只在 --state-dir 啟用，不送訊息。
        for (i, a) in args.enumerated() where a == "--outbox-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), ["seed", "seed-delivered", "recover", "dump"].contains(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                let output: String
                do {
                    if let self, let id = self.store.selected, let pane = self.workspace.panes[id] as? ChatPane {
                        output = try pane.probeOutbox(parts[1])
                    } else { output = "沒有聊天格\n" }
                } catch { output = "outbox-probe: \(error)\n" }
                try? output.write(toFile: parts[2], atomically: true, encoding: .utf8)
            }
        }
        // --draft-probe／--draft-image-probe "秒數:檔案"（限 --state-dir）：等自動存檔後輸出 JSON 與圖片檔清單。
        // 圖片版用 #7、edited=true 的小 PNG，測編號有缺口也能原樣還原；不拿輸入框焦點。
        for (i, a) in args.enumerated() where (a == "--draft-probe" || a == "--draft-image-probe") && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let resultPath = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected,
                      let pane = self.workspace.panes[id] as? ChatPane else {
                    try? "沒有聊天格\n".write(toFile: resultPath, atomically: true, encoding: .utf8)
                    return
                }
                let window = pane.inputBar.window
                let responder = window?.firstResponder
                let keyWindow = NSApp.keyWindow
                if a == "--draft-image-probe" {
                    guard !pane.inputBar.hasPendingInput,
                          let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOQa/rwH4QZYAwAVgwKPaFOh1UAAAAASUVORK5CYII=") else {
                        try? "輸入框已有草稿，未覆寫\n".write(toFile: resultPath, atomically: true, encoding: .utf8)
                        return
                    }
                    pane.inputBar.textView.string = "圖片草稿測試 abc [Image #7]"
                    pane.inputBar.restoreImages([DraftPersistence.Image(data: png, mediaType: "image/png", no: 7, edited: true)])
                    pane.inputBar.textView.didChangeText()
                } else {
                    pane.inputBar.setDraft("跨啟動草稿測試 abc")
                }
                let focusUnchanged = window?.firstResponder === responder && NSApp.keyWindow === keyWindow
                // 不手動存：等打字後約 1 秒的自動存檔（測的就是當掉前有沒有自己寫下去）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    let directory = self.store.directory.appendingPathComponent("drafts", isDirectory: true)
                    let prefix = id.uuidString.lowercased()
                    let url = directory.appendingPathComponent("\(prefix).json")
                    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "（尚無草稿檔）"
                    let imageFiles = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.lastPathComponent.hasPrefix("\(prefix)-img-") && ["png", "jpg"].contains($0.pathExtension) }
                        .map(\.path).sorted()
                    let images = pane.inputBar.draftImages
                    let output = "path=\(url.path)\n\(contents)\nimageFiles=\(imageFiles)\n" +
                        "attachments=\(images.count) imageNos=\(images.map(\.no)) edited=\(images.map(\.edited)) focusUnchanged=\(focusUnchanged)\n"
                    try? output.write(toFile: resultPath, atomically: true, encoding: .utf8)
                }
            }
        }
        // --input-dump "秒數:檔案"（限 --state-dir）：輸出文字、附件數、原編號與編輯狀態，測重開後還原。
        for (i, a) in args.enumerated() where a == "--input-dump" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let pane = self.workspace.panes[id] as? ChatPane else {
                    try? "沒有聊天格\n".write(toFile: parts[1], atomically: true, encoding: .utf8); return
                }
                let images = pane.inputBar.draftImages
                let output = "輸入框=[\(pane.inputBar.textView.string)]\n" +
                    "attachments=\(images.count) imageNos=\(images.map(\.no)) edited=\(images.map(\.edited))\n" +
                    "\(pane.inputBar.scrollerState) \(pane.inputBar.metricsForTest)\n"
                try? output.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --toggle-right "秒數"：像按 F4（開關右側欄）
        for (i, a) in args.enumerated() where a == "--toggle-right" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.toggleRightPanel() }
        }
        // --right-stall-probe "秒數:分頁:檔案"（限 --state-dir）：那時打開右欄並切到分頁，3 秒後像按 F4 收起，
        //   寫「maxStallMs=最長停頓毫秒 collapsed1s=yes|no」（1 秒內右欄是否已收完）。考題 C21 用
        for (i, a) in args.enumerated() where a == "--right-stall-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let tab = RightTab.named(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.showRightPanel(tab: tab) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec + 3) { [weak self] in
                RightPanelPerf.reset()
                self?.main.toggleRightPanel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec + 4) { [weak self] in
                let gone = self?.main.host.debugRightPanel().contains("- - on=") == true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    _ = RightPanelPerf.report("probe")
                    let out = String(format: "maxStallMs=%.0f collapsed1s=%@\n", RightPanelPerf.maxGap, gone ? "yes" : "no")
                    try? out.write(toFile: parts[2], atomically: true, encoding: .utf8)
                }
            }
        }
        // --frame-stats "開始秒數:標籤:檔案"：開始秒數起記錄右欄滑動動畫的每幀耗時，1 秒後把摘要附加寫進檔案（接在 --toggle-right 前一點開始）
        for (i, a) in args.enumerated() where a == "--frame-stats" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { RightPanelPerf.reset() }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec + 1.5) {
                let line = RightPanelPerf.report(parts[1])
                if let h = FileHandle(forWritingAtPath: parts[2]) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
                else { try? line.write(toFile: parts[2], atomically: true, encoding: .utf8) }
            }
        }
        // --trace-right "開始秒數:檔案"：從那時起 1.5 秒，每 1/60 秒記一行「經過毫秒 視窗內容寬 主內容寬 右欄左緣 右欄寬」
        for (i, a) in args.enumerated() where a == "--trace-right" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let t0 = ProcessInfo.processInfo.systemUptime
                var out = ""
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
                    guard let self else { tm.invalidate(); return }
                    let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
                    out += "\(ms) \(self.main.host.debugRightPanel())\n"
                    if ms > 1500 { tm.invalidate(); try? out.write(toFile: path, atomically: true, encoding: .utf8) }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        // --toggle-sidebar "秒數"：收起／打開側欄
        for (i, a) in args.enumerated() where a == "--toggle-sidebar" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.toggleSidebar() }
        }
        // --suggest "秒數:文字"：目前那格聊天的輸入框顯示這句灰字建議（測建議的畫法）
        for (i, a) in args.enumerated() where a == "--suggest" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.suggestion = text
            }
        }
        // --organizer "秒數"：打開整理對話視窗
        for (i, a) in args.enumerated() where a == "--organizer" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.showOrganizer() }
        }
        // --organizer-dump "秒數:檔案"：整理對話「對話」分頁會列的對話、「資料夾」分頁的對話數
        for (i, a) in args.enumerated() where a == "--organizer-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                var out = st.organizerConversations.map { "對話：\($0.title)" }
                out += st.projects.map { p in "資料夾：\(p.name) \(st.organizerConversations.filter { $0.projectID == p.id }.count) 段（全部 \(st.conversations.filter { $0.projectID == p.id }.count)）" }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --new-conv "秒數"：像按「新對話」（跳出資料夾選單）
        for (i, a) in args.enumerated() where a == "--new-conv" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newConversation() }
        }
        // 環境變數 CODENV_FAKE_RUNNING=<個數>（要有 --state-dir）：開機 3 秒後在目前選的對話塞假的背景項目，拍「正在跑」版面用
        if args.contains("--state-dir"), let n = Int(ProcessInfo.processInfo.environment["CODENV_FAKE_RUNNING"] ?? ""), n > 0 {
            for t in [3.0, 6.0, 9.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in if let id = self?.store.selected { SessionActivity.shared.injectFakeForTest(id, count: n) } }
            }
        }
        // --new-chat "秒數:標題"：幾秒後開一段真的聊天室（不是草稿，不會被自動刪；放進目前那格）。測版面、掛件、⌘ W 用
        for (i, a) in args.enumerated() where a == "--new-chat" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let pid = self.store.projects.first?.id ?? self.store.addProject(path: NSHomeDirectory()).id
                var c = self.store.createConversation(in: pid)
                self.store.rename(c.id, to: String(parts[1]), byUser: true)
                c = self.store.conversation(c.id) ?? c
                self.store.show(c.id)
            }
        }
        // --conv-session "秒數:標題:UUID"：把那段聊天室的 Claude 對話編號換成指定的（測喚醒、接回用：配合先用同編號開好的紀錄檔）；--conv-place "秒數:標題"：把它擺進目前那格
        for (i, a) in args.enumerated() where a == "--conv-session" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let u = UUID(uuidString: parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let n = self.store.conversations.firstIndex(where: { $0.title == parts[1] }) else { return }
                self.store.conversations[n].claudeSession = u
            }
        }
        for (i, a) in args.enumerated() where a == "--conv-place" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.store.show(c.id)
            }
        }
        // --new-chat-at "秒數:資料夾:標題"：在那個資料夾開一段真的聊天室，不顯示（測「點不同資料夾的聊天室」）
        for (i, a) in args.enumerated() where a == "--new-chat-at" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let pid = self.store.projects.first(where: { $0.path == parts[1] })?.id ?? self.store.addProject(path: parts[1]).id
                let c = self.store.createConversation(in: pid)
                self.store.rename(c.id, to: parts[2], byUser: true)
            }
        }
        // --sidebar-open "秒數:標題"：像在側欄點那段聊天室
        for (i, a) in args.enumerated() where a == "--sidebar-open" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.store.open(c.id)
            }
        }
        // --f2 "秒數:名字"：像按 F2 並在輸入框打這個名字（選取整個 Window 時改 Window，不然改紫框那格）；--window-select "秒數"：像點上方 Window 分頁
        for (i, a) in args.enumerated() where a == "--f2" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.f2Rename(answer: parts[1]) }
        }
        for (i, a) in args.enumerated() where a == "--window-select" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in if let wi = self?.store.windowIndex { self?.store.toggleWindowSelection(at: wi) } }   // 像點目前這個 Window 的分頁（再來一次＝回原本那格）
        }
        // --window-rename "秒數:名字"：像 Ctrl+A , 幫目前 Window 取名（空字串＝清空）
        for (i, a) in args.enumerated() where a == "--window-rename" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.renameWindow(parts[1]) }
        }
        // --window-move "秒數:標題:第幾個Window"：把那段聊天室搬到另一個 Window（測框跟著成員變）
        for (i, a) in args.enumerated() where a == "--window-move" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.store.selectWindow(at: n)
                self.store.split(vertical: false, with: c.id)
            }
        }
        // --new-conv-at "秒數:資料夾"：幾秒後直接在那個資料夾開新對話（不跳資料夾選單；測聊天室畫面用）
        for (i, a) in args.enumerated() where a == "--new-conv-at" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let dir = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newConversation(at: dir) }
        }
        // --store-op "秒數:動作:第幾段:參數"：shift（參數＝上移負數／下移正數）、archive（1 封存／0 取消）、unread（1 標成做完沒看／0 取消）、before（排到第參數段前面）、handoff（參數＝0，略過確認框，仍跑全部開始前檢查）。段數從 0 數。
        // 名稱操作另用 "秒數:pickcommander:名稱"，不需要對話索引，與左欄點選一樣先清獨立視窗 scope 再 selectSession。
        for (i, a) in args.enumerated() where a == "--store-op" && i + 1 < args.count {
            let named = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            if named.count == 3, named[1] == "pickcommander" {
                guard let sec = Double(named[0]), sec.isFinite, sec >= 0 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                    guard let st = self?.store as Store?,
                          let session = st.sessions.first(where: { $0.area == nil && $0.groups != nil && $0.name == named[2] }) else { return }
                    st.scope = nil
                    st.selectSession(session.id)
                }
                continue
            }
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), sec.isFinite, sec >= 0, let n = Int(parts[2]), let v = Int(parts[3]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, self.store.conversations.indices.contains(n) else { return }
                let id = self.store.conversations[n].id
                switch parts[1] {
                case "shift": self.store.shift(id, by: v)
                case "archive": self.store.setArchived(id, v == 1)
                case "before": if v < self.store.conversations.count { self.store.reorder(id, before: self.store.conversations[v].id) }
                case "after": if v < self.store.conversations.count { self.store.reorder(id, after: self.store.conversations[v].id) }
                case "compact": (self.workspace.panes[id] as? ChatPane)?.compact()
                case "handoff":
                    guard let c = self.store.conversation(id), let dir = self.store.project(c.projectID)?.path else { break }
                    self.main.startHandoff(c, directory: dir)
                case "unread": if v == 1 { self.store.unread.insert(id) } else { self.store.unread.remove(id) }   // 分頁／側欄的小藍點
                // 掛件框（Bundles.swift）：gemini／notebook＝掛到第 n 段（參數不用）；leave＝離開框；dissolve＝解散第 n 段所在的框；
                // movegroup＝把第 n 段所在的框整個搬到第 v 組；attach＝把第 n 段（瀏覽器）改成掛在第 v 段上；open＝打開第 n 段的第 v 個掛件
                // site＝這格瀏覽器網址換成「第 v 種」：0 Gemini 對話 A、1 NotebookLM 筆記本 B、2 其他網站（假網址，不連網）；
                // sitesw0／sitesw1＝像 ⌥ 八宮格那樣切回 Gemini／NotebookLM，把要載入的網址（或 nil）和 lastURLs 寫到 stderr 旁的 browser-test.log
                case "site":
                    let urls = ["https://gemini.google.com/app/88ec0001", "https://notebooklm.google.com/notebook/b2b20002", "https://example.org/x"]
                    self.store.noteBrowserURL(id, urls[min(v, 2)])
                case "sitesw0", "sitesw1":
                    let r = self.store.switchBrowserSite(id, to: parts[1] == "sitesw0" ? .gemini : .notebooklm)
                    let line = "切換→\(parts[1]) 載入=\(r ?? "nil") 目前=\(self.store.conversation(id)?.browser ?? "") lastURLs=\(self.store.conversation(id)?.lastURLs ?? [:])\n"
                    let f = self.store.directory.appendingPathComponent("site-test.log")
                    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
                case "sandbox": self.main.toggleSandbox(id)   // 右鍵「在沙盒裡跑（nono）」
                case "show": self.store.show(id)   // 放進紫框那格（測 ⌘ ⇧ B 依選中的格子決定掛不掛）
                case "focus": self.store.editWindow { $0.focused = id }   // 紫框移到第 n 段（它要已經在目前 Window）
                case "closewin": self.store.closeWindow()   // ⌃ ⌘ W（關掉目前整個 Window）
                case "reopenwin": self.store.reopenClosedWindow()   // ⌘ ⇧ T
                case "newwindow": self.store.newWindow(with: id)   // 開新 Window 放第 n 段
                case "window": self.store.selectWindow(at: v)
                case "dframe": self.main.detachedWindows.values.first?.window?.setFrame(NSRect(x: 120 + CGFloat(v), y: 210, width: 640, height: 480), display: true)   // 把（第一個）獨立視窗搬到固定位置（測記位置用）
                case "dscreen": if let f = self.main.detachedWindows.values.first?.window { f.setFrame(NSRect(x: 99000, y: 99000, width: 5000, height: 4000), display: false) }   // 搬到所有螢幕外面
                case "winoffset": self.store.selectWindow(offset: v)   // ⌘ ⇧ [ ／ ] 切 Window 分頁（v＝+1／−1）
                case "scope": self.store.scope = v == 1 ? self.store.sessions.flatMap(\.windows).first { $0.detached }?.id : nil   // 模擬獨立視窗拿到（1）或還回（0）焦點      // 切到第 v 個 Window
                case "splitwith": self.store.split(vertical: false, with: id)   // 從紫框那格左右切開、放第 n 段
                case "gemini": self.store.addGadget(.gemini, to: id)
                case "notebook": self.store.addGadget(.notebooklm, to: id)
                case "leave": self.store.setBundle(id, nil)
                case "dissolve": if let b = self.store.conversation(id)?.bundle { self.store.dissolveBundle(b) }
                case "movegroup": if let b = self.store.conversation(id)?.bundle, v < self.store.groups.count { self.store.moveBundle(b, toGroup: self.store.groups[v].id) }
                case "attach": if v < self.store.conversations.count { self.store.attachBrowser(id, to: self.store.conversations[v].id) }
                case "open": if let b = self.store.conversation(id)?.bundle, v < self.store.gadgets(of: b).count { self.store.openGadget(self.store.gadgets(of: b)[v].id) }
                // ⌘ W（closew）、⌘ ⇧ T（reopen）、側欄點第 n 段（sidebar）、⌘ ⇧ B（togglebundle）：不按鍵盤，直接呼叫同一個函式
                case "bundleset":   // 把第 n 段放進第 v 段所在的掛件框（沒有框就新開一個）；框沒有掛件就掛一個 Gemini（都不擺進版面）
                    guard v < self.store.conversations.count else { break }
                    let anchor = self.store.conversations[v].id
                    let b = self.store.conversation(anchor)?.bundle ?? UUID()
                    self.store.setBundle(anchor, b); self.store.setBundle(id, b)
                    if self.store.gadgets(of: b).isEmpty { _ = self.store.addGadget(.gemini, to: anchor) }
                case "emptywindow":   // 開一個只有一格「空格子」的新 Window（跟 ⌘ T 一樣）
                    self.store.newWindow(with: nil)
                    let slot = UUID()
                    self.store.editWindow { $0.root = .leaf(slot); $0.focused = slot }
                    Store.emptySlots.insert(slot)
                case "detach": self.main.detachWindowTab(v, at: NSPoint(x: 700, y: 500))   // 把主視窗分頁列第 v 個 Window 拉出去變獨立視窗
                case "closedetached": self.main.detachedWindows.values.first?.window?.close()   // 關掉（第一個）獨立視窗＝回到主視窗
                case "place": if v < self.store.conversations.count { self.store.place(id, near: self.store.conversations[v].id, edge: .right) }   // 像從側欄把第 n 段拖到第 v 段右邊（v 在哪個視窗就放哪；在主視窗＝scoped(nil)）
                case "closesession": self.store.closeSession()   // 關掉目前的 Session
                case "closew": self.store.closePaneOrWindow()
                case "reopen": self.store.reopenClosedWindow()
                case "sidebar": self.store.open(id, replaceFocused: false)
                case "sidebarshift": self.store.open(id, replaceFocused: true)   // ⇧ 點側欄：放進目前紫框那格（換掉它），不開新 Window
                case "togglebundle": self.store.toggleBundle(from: id)
                default: break
                }
            }
        }
        // --daily-handoff-now "秒數"：到時候立刻跑一輪每日交接（略過功能開關，其他條件照常；--fake-now 影響分界計算）。只在有 --state-dir 時有效，且一定要有 --handoff-fake。
        // --daily-handoff-gap "秒數"：每件之間的間隔（預設 20 秒）；--daily-handoff-auto：測試實例也開自動定時檢查。
        for (i, a) in args.enumerated() where a == "--daily-handoff-now" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.dailyHandoff.check("測試", force: true) }
        }
        // --handoff-dump "秒數:檔案"：可重複指定，輸出 JSON；對話與排程的 conversation 都用相同的 UUID 前 8 碼。
        for (i, a) in args.enumerated() where a == "--handoff-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let st = self.store else { return }
                func field<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
                func short(_ id: UUID?) -> Any { field(id.map { String($0.uuidString.lowercased().prefix(8)) }) }
                let frames = st.windowFrames
                let conversations: [[String: Any]] = st.conversations.map { c in
                    ["id": short(c.id), "uuid": c.id.uuidString.lowercased(), "title": c.title,
                     "manualArchive": field(c.manualArchive), "bundle": short(c.bundle), "gadgetOf": short(c.gadgetOf),
                     "permissionMode": field(c.permissionMode), "sandbox": field(c.sandbox), "order": field(c.order),
                     "projectID": c.projectID.uuidString.lowercased(), "groupID": short(c.groupID),
                     "windowFrame": short(frames[c.id]?.window), "windowName": field(frames[c.id]?.name),
                     "browser": field(c.browser), "lastURLs": field(c.lastURLs),
                     "lastHandoffAt": field(c.lastHandoffAt.map { ISO8601DateFormatter().string(from: $0) })]
                }
                let f = ISO8601DateFormatter()
                let schedules: [[String: Any]] = ScheduleStore.shared.items.map { s in
                    ["id": s.id.uuidString.lowercased(), "conversation": short(s.conversation),
                     "conversationID": s.conversation.uuidString.lowercased(), "pendingRun": field(s.pendingRun.map(f.string)),
                     "nextAt": field(s.nextAt.map(f.string)), "enabled": s.enabled,
                     "runs": s.runs.map { ["at": f.string(from: $0.at), "due": f.string(from: $0.due), "result": $0.result] }]
                }
                let folder = st.directory.appendingPathComponent("handoffs", isDirectory: true)
                var files: [String] = [], errors: [String] = []
                if FileManager.default.fileExists(atPath: folder.path),
                   let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], errorHandler: { url, error in
                       errors.append("\(url.path)：\(error.localizedDescription)"); return true
                   }) {
                    for case let url as URL in entries {
                        do { if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url.path) } }
                        catch { errors.append("\(url.path)：\(error.localizedDescription)") }
                    }
                }
                let object: [String: Any] = ["conversations": conversations, "schedules": schedules, "handoffs": files.sorted(), "errors": errors,
                                              "chiefs": st.sessions.map { field($0.chief.map { String($0.uuidString.lowercased().prefix(8)) }) },
                                              "selected": short(st.selected), "currentSession": short(st.currentSession),
                                              "windows": st.sessions.flatMap { s in s.windows.map { w -> [String: Any] in
                                                  ["session": short(s.id), "window": short(w.id), "name": w.name, "leaves": (w.root?.leaves ?? []).map { short($0) },
                                                   "focused": short(w.focused), "current": s.current == w.id] } }]
                do {
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
                } catch { EventLog.log("測試", "交接狀態輸出失敗：\(error.localizedDescription)") }
            }
        }
        // --bundle-anim "秒數:動畫秒數"：把側欄所有掛件框停在描邊動畫的第幾秒（負數＝放開，回到正常）；可以給好幾次
        for (i, a) in args.enumerated() where a == "--bundle-anim" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]), let at = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { BundleAnim.shared.frozen = at < 0 ? nil : at }
        }
        // --drag-divider "秒數:第幾條:比例"：像用滑鼠把目前 Window 的第幾條分隔線（外層先）拖到這個比例（測 ⌘ Q 後比例有沒有記住）
        for (i, a) in args.enumerated() where a == "--drag-divider" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]), let r = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.host.testDragDivider(index: n, ratio: CGFloat(r)) }
        }
        // --quit "秒數"：走跟 ⌘ Q 一樣的結束流程（applicationShouldTerminate → applicationWillTerminate 存檔）
        for (i, a) in args.enumerated() where a == "--quit" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { NSApp.terminate(nil) }
        }
        // --dump-tree "秒數:檔案"：每個 Window 的版面樹和每一層的比例
        for (i, a) in args.enumerated() where a == "--dump-tree" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                func show(_ n: PaneNode) -> String {
                    switch n {
                    case .leaf(let id): return st.conversation(id)?.title ?? "空"
                    case .split(let v, let r, let a, let b): return "[\(v ? "上下" : "左右") \(String(format: "%.3f", r)): \(show(a)) | \(show(b))]"
                    }
                }
                var out = st.sessions.flatMap { s in s.windows.map { w in "\(s.name)/\(w.name)：\(w.root.map(show) ?? "-")（紫框＝\(w.focused.flatMap { st.conversation($0)?.title } ?? "-")\(w.zoomed ? "，放大中" : "")）" } }
                // 目前 Window 裡每個掛件圖示是亮還是暗（側欄的 shownGadgets 用同一個算法），和 ⌘ ⇧ T 能找回幾個
                let here = Set((st.currentWindow?.root?.leaves ?? []).filter { !PaneSlide.shared.isLeaving($0) })
                out.append("掛件圖示：" + st.conversations.filter(\.isGadget).map { "\($0.title)＝\(here.contains($0.id) ? "亮" : "暗")" }.joined(separator: "、"))
                out.append("可找回的 Window：\(Store.closed.filter { if case .window = $0 { return true } else { return false } }.count)")
                try? out.joined(separator: "\n").write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --pane-slide "秒數:動畫秒數"：掛件格子滑進／滑出的動畫停在第幾秒（負數＝放開，照常跑完）；可以給好幾次
        for (i, a) in args.enumerated() where a == "--pane-slide" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]), let at = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { PaneSlide.shared.frozen = at < 0 ? nil : at; PaneSlide.shared.notify() }
        }
        // --bundle-dump "秒數:檔案"：每段對話的組、掛件框、掛件和網址（測掛件框）
        for (i, a) in args.enumerated() where a == "--bundle-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let st = self.store as Store? else { return }
                let short = { (u: UUID?) in u.map { String($0.uuidString.prefix(4)) } ?? "-" }
                var out = st.conversations.map { c in
                    "\(c.title)\t組=\(st.group(st.groupOf(c))?.name ?? "-")\t框=\(short(c.bundle))\t掛件of=\(short(c.gadgetOf))\t網址=\(c.browser ?? "-")\t在版面=\(st.locate(c.id) != nil)"
                }
                // Window 框（取過名字的 Window，Store.windowFrames）：名字和成員
                let wf = st.windowFrames
                for name in Set(wf.values.map(\.name)).sorted() { out.append("Window框：\(name)＝" + st.conversations.filter { wf[$0.id]?.name == name }.map(\.title).joined(separator: "、")) }
                out.append("選取整個Window：\(st.windowSelected)")
                out.append("Window框數：\(Set(wf.values.map(\.window)).count)")
                out.append("格子：\(st.currentWindow?.root?.leaves.count ?? 0)")
                let fr = self.main.window?.firstResponder
                let owner = self.workspace.panes.first { (_, v) in (fr as? NSView).map { $0.isDescendant(of: v) } ?? false }
                out.append("版面：" + (st.currentWindow?.root?.leaves ?? []).map { st.conversation($0)?.title ?? "空" }.joined(separator: "｜"))
                if case .split(_, let r, _, _)? = st.currentWindow?.root { out.append("最外層比例：\(String(format: "%.3f", r))") }
                out.append("紫框：\(st.currentWindow?.focused.flatMap { st.conversation($0)?.title } ?? "-")")
                out.append("焦點：\(fr.map { String(describing: type(of: $0)) } ?? "nil") 在 \(owner.flatMap { st.conversation($0.key)?.title } ?? "-")")
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --set-default-effort "秒數:強度"：像在模型面板把拉桿拉到這段、按「設為預設」（要先 --model-panel 打開面板）
        for (i, a) in args.enumerated() where a == "--set-default-effort" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let m = ModelPanelModel.last, let i = m.levels.firstIndex(of: v) else { return }
                m.index = Double(i)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let e = m.effort { m.onSetDefault?(e) } }
            }
        }
        // --chat-stop "秒數"：幾秒後按停止
        for (i, a) in args.enumerated() where a == "--chat-stop" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.interrupt()
            }
        }
        // --chat-text "秒數:檔案"：幾秒後把聊天畫面上的文字（網頁的 innerText）寫進檔案
        for (i, a) in args.enumerated() where a == "--chat-text" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.evaluate("document.body.innerText") { s in try? s.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        }
        // --focus-move "秒數:檔案"：程式碼區聊天室裡依序按 ⌃ A → ↓ ↑ ←，每步回報焦點在哪（聊天／編輯器／執行結果）
        for (i, a) in args.enumerated() where a == "--focus-move" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane, let lab = p.codeLab, let w = p.window else {
                    try? "沒有程式碼區聊天室".write(toFile: path, atomically: true, encoding: .utf8); return
                }
                func spot() -> String {
                    guard let v = w.firstResponder as? NSView else { return "nil" }
                    if v === p.inputBar.textView { return "聊天輸入框" }
                    if v.isDescendant(of: lab) { return v is WKWebView ? "編輯器" : "執行結果(\(type(of: v)))" }
                    return String(describing: type(of: v))
                }
                let noAI = lab.mode == .noAI          // 不用 AI：聊天收起來，從編輯器起步、測左右
                if noAI { lab.focusEditor() } else { _ = p.focusInput() }
                var out = ["開始：\(spot())"]
                let steps: [(String, (Int, Int))] = noAI ? [("→", (1, 0)), ("←", (-1, 0)), ("←", (-1, 0))] : [("→", (1, 0)), ("↓", (0, 1)), ("↑", (0, -1)), ("←", (-1, 0))]
                for (name, d) in steps {
                    self.main.moveFocus(dx: d.0, dy: d.1)
                    out.append("\(name)：\(spot())")
                }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --fake-timers：塞幾個假的計時器（不碰真桌寵；只在 --state-dir 測試時有效）
        if args.contains("--fake-timers") {
            PetTimers.shared.inject(id: "a", label: "模型評測 gpt-oss 全部題目", eta: 600, startedAgo: 200)
            PetTimers.shared.inject(id: "b", label: "下載模型", eta: nil, done: 12, total: 40, startedAgo: 60)
            PetTimers.shared.inject(id: "c", label: "超時的編譯", eta: 60, startedAgo: 300)
            PetTimers.shared.inject(id: "d", label: "做完了", eta: 60, finished: true)
        }
        // --area-add-probe 輸出檔：在測試資料裡造兩個總指揮（c2 涵蓋 c1 底下一個叫「共名」的子組），
        // 叫 c1 建同名同父的區：必須失敗、「共名」那組仍在（舊版會把它 removeGroup 刪掉）；再刪該組，總指揮涵蓋清單不能留失效 id
        if let i = args.firstIndex(of: "--area-add-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let st = self?.main.store else { return }
                let r1 = ConvGroup(name: "R1"); var z = ConvGroup(name: "共名"); z.parentID = r1.id
                st.groups.append(contentsOf: [r1, z])
                let p1 = Project(name: "p1", path: "/tmp", groupID: r1.id), p2 = Project(name: "p2", path: "/tmp", groupID: z.id)
                st.projects.append(contentsOf: [p1, p2])
                var c1 = Conversation(projectID: p1.id, title: "chief1"); c1.groupID = r1.id
                var c2 = Conversation(projectID: p2.id, title: "chief2"); c2.groupID = z.id
                st.conversations.append(contentsOf: [c1, c2])
                let s1 = SessionLayout(name: "S1", windows: [], groups: [r1.id], chief: c1.id)
                let s2 = SessionLayout(name: "S2", windows: [], groups: [z.id], chief: c2.id)
                st.sessions.append(contentsOf: [s1, s2])
                let r = st.commanderAreaAdd(caller: c1.id.uuidString, name: "共名", parent: nil)
                var lines = ["ok=\(r["ok"] as? Bool ?? true)", "error=\(r["error"] as? String ?? "")"]
                lines.append("zStillThere=\(st.groups.contains { $0.id == z.id })")
                st.removeGroup(z.id)
                lines.append("staleIdCleared=\(!(st.sessions.first { $0.id == s2.id }?.groups ?? []).contains(z.id))")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --hang-send：把 send 指令換成永遠不回的（測 BrowserServer 的逾時：--wait 要等到 timeout、不能固定 15 秒就叫呼叫端重送）
        if args.contains("--hang-send"), args.contains("--state-dir") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { BrowserServer.shared.sendChat = { _, _, _, _, _, _ in } }
        }
        // --usage-date-probe 輸出檔：friendlyDate 沒有年份的字串跨年時要選對年（用假的「現在」，不碰真資料）
        if let i = args.firstIndex(of: "--usage-date-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let cal = Calendar.current
                func at(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
                func ymd(_ d: Date?) -> String { d.map { let c = cal.dateComponents([.year, .month, .day], from: $0); return "\(c.year!)-\(c.month!)-\(c.day!)" } ?? "nil" }
                var lines: [String] = []
                lines.append("dec_to_jan=\(ymd(UsageMonitor.friendlyDate("Jan 1 at 12am", zone: nil, now: at(2026, 12, 30))))")
                lines.append("jan_to_dec=\(ymd(UsageMonitor.friendlyDate("Dec 31 at 11pm", zone: nil, now: at(2027, 1, 2))))")
                lines.append("same_year=\(ymd(UsageMonitor.friendlyDate("Nov 9 at 1am", zone: nil, now: at(2026, 11, 8))))")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --board-bad-probe 輸出檔：在測試資料夾的 collab.json 放 2 個好目標＋1 個壞目標（缺 title），loadTodos 要讀到 2 個，原檔不動
        if let i = args.firstIndex(of: "--board-bad-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let json = #"{"items":[],"goals":[{"id":"g1","title":"好一","status":"active","steps":[]},{"id":"g2","status":"active"},{"id":"g3","title":"好二","status":"active","steps":[]}]}"#
                try? json.write(to: CollabBoardModel.todoFile, atomically: true, encoding: .utf8)
                let (_, goals) = CollabBoardModel.loadTodos()
                let intact = (try? String(contentsOf: CollabBoardModel.todoFile, encoding: .utf8)) == json
                try? "goals=\(goals.map(\.id).joined(separator: ","))\nfileIntact=\(intact)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --web-crash-loop-probe "秒:輸出檔"：1 分鐘內連殺網頁程序 5 次（每次等它重載完）；重載最多 3 次，之後不再重載（ready 累計 1+3=4 次）
        if let i = args.firstIndex(of: "--web-crash-loop-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let sec = Double(parts[0]), parts[1].hasPrefix("/") {
                let outFile = parts[1]
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                    guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane else {
                        try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8); return
                    }
                    var n = 0
                    func next() {
                        if n == 5 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                let shown = p.crashOverlayShownForTest
                                p.pressReloadAfterCrashForTest()      // 按「重新載入」：提示要收掉、網頁要重新載入回來
                                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                    try? "ready_count=\(p.readyCountForTest)\nready_now=\(p.webReadyForTest)\noverlay_shown=\(shown)\noverlay_after_reload=\(p.crashOverlayShownForTest)\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                                }
                            }
                            return
                        }
                        n += 1
                        p.killWebProcessForTest()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: next)
                    }
                    next()
                }
            }
        }
        // --web-crash-probe "秒:輸出檔"：把聊天網頁的 WebContent 程序殺掉，幾秒後網頁要自己重載回來（ready 重新成立、頁面有內容）
        if let i = args.firstIndex(of: "--web-crash-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let sec = Double(parts[0]), parts[1].hasPrefix("/") {
                let outFile = parts[1]
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                    guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane else {
                        try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8); return
                    }
                    let before = p.readyCountForTest
                    p.killWebProcessForTest()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        try? "ready_count_before=\(before)\nready_count_after=\(p.readyCountForTest)\nready_after=\(p.webReadyForTest)\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --keychain-timeout-probe 輸出檔：把 security 換成睡 30 秒的假腳本，keychain() 要在幾秒內回 nil（不能卡住）
        if let i = args.firstIndex(of: "--keychain-timeout-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let fake = (out as NSString).deletingLastPathComponent + "/fake-security"
                try? "#!/bin/sh\nsleep 30\n".write(toFile: fake, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
                NonoSandbox.securityPath = fake
                NonoSandbox.keychainTimeout = 2
                let t0 = Date()
                let r = NonoSandbox.keychain(service: "codenv-probe-none")
                let secs = Date().timeIntervalSince(t0)
                try? "result_nil=\(r == nil)\nsecs=\(Int(secs))\nfast=\(secs < 6)\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --update-check-probe "網址|git資料夾|輸出檔"：對那個網址做一次更新檢查（逾時縮成 3 秒）；網址指到不回應的伺服器時，要在幾秒內失敗而不是卡住
        if let i = args.firstIndex(of: "--update-check-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].components(separatedBy: "|")
            if parts.count == 3 {
                let url = parts[0], root = parts[1], out = parts[2]
                SourceUpdate.gitTimeout = 3
                DispatchQueue.global().async {
                    let t0 = Date()
                    let r = SourceUpdate.probeLatest(in: URL(fileURLWithPath: root), url: url)
                    let secs = Date().timeIntervalSince(t0)
                    try? "result=\(r)\nsecs=\(Int(secs))\n".write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
        }
        // --runner-dash-probe 輸出檔：檔名以 - 開頭的 C++ 檔做 F9 檢查，不能被 g++ 當成選項
        if let i = args.firstIndex(of: "--runner-dash-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let dir = (out as NSString).deletingLastPathComponent + "/dashproj"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let f = dir + "/-Wall.cpp"
                try? "int main() { return 0; }\n".write(toFile: f, atomically: true, encoding: .utf8)
                let bad = dir + "/-bad.cpp"
                try? "int main() { return undefined_name; }\n".write(toFile: bad, atomically: true, encoding: .utf8)
                CodeRunner.check(file: f) { status, _, _ in
                    let cmd = CodeRunner.runCommand(file: f)
                    CodeRunner.check(file: bad) { st2, diags, _ in
                        try? "status_ok=\(status == .ok)\ncmd_has_dotslash=\(cmd.contains("'./-Wall.cpp'"))\nbad_failed=\(st2 == .failed)\nbad_diag_count=\(diags.count)\n".write(toFile: out, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --schedule-marker-probe 輸出檔：同一個排程隔年同月日同時間的防重送標記不能一樣
        if let i = args.firstIndex(of: "--schedule-marker-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let sch = WakeSchedule(conversation: UUID(), text: "x")
                func due(_ y: Int) -> Date { Calendar.current.date(from: DateComponents(year: y, month: 3, day: 5, hour: 9, minute: 0))! }
                let a = ScheduleStore.marker(sch, due(2026)), b = ScheduleStore.marker(sch, due(2027))
                try? "differ=\(a != b)\nmarker=\(a)\nlegacy=\(ScheduleStore.legacyMarker(a))\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --lid-display-filter-probe 輸出檔：哪些螢幕算「實體外接」（內建、虛擬／未知廠商、睡眠中的都不算）
        if let i = args.firstIndex(of: "--lid-display-filter-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let ok = CGSize(width: 600, height: 340)
                func f(_ b: Bool, _ v: UInt32, _ m: UInt32, _ a: Bool, _ sz: CGSize = ok) -> Bool { RealLidEnv.isRealExternal(builtin: b, vendor: v, model: m, asleep: a, size: sz) }
                let lines = ["real_external=\(f(false, 0x0610, 1, false))", "builtin=\(f(true, 0x0610, 1, false))",
                             "virtual_unknown_vendor=\(f(false, 0xFFFF_FFFF, 1, false))", "virtual_zero_vendor=\(f(false, 0, 0, false))", "asleep=\(f(false, 0x0610, 1, true))",
                             "virtual_no_size=\(f(false, 505, 1, false, .zero))"]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --drop-clean-probe 輸出檔：用暫存資料夾測拖放暫存清理（不碰真的共用資料夾）：舊的沒人引用→刪、舊的被草稿引用→留、新的→留
        if let i = args.firstIndex(of: "--drop-clean-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let fm = FileManager.default
                let root = URL(fileURLWithPath: (out as NSString).deletingLastPathComponent).appendingPathComponent("dropclean", isDirectory: true)
                let folder = root.appendingPathComponent("drop", isDirectory: true), state = root.appendingPathComponent("state", isDirectory: true)
                try? fm.removeItem(at: root)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true); try? fm.createDirectory(at: state.appendingPathComponent("drafts"), withIntermediateDirectories: true)
                let old = Date().addingTimeInterval(-3 * 86400)
                func make(_ name: String, date: Date) -> URL {
                    let d = folder.appendingPathComponent(name, isDirectory: true); try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                    try? "x".write(to: d.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: d.path); return d
                }
                let unref = make("unref", date: old), ref = make("ref", date: old), fresh = make("fresh", date: Date())
                // 草稿 JSON 的斜線被轉成 \/（JSONEncoder 預設）
                let draft = "{\"filePaths\":[\"\(ref.appendingPathComponent("a.png").path.replacingOccurrences(of: "/", with: "\\/"))\"]}"
                try? draft.write(to: state.appendingPathComponent("drafts/c1.json"), atomically: true, encoding: .utf8)
                // 被隔離的壞草稿（不是合法 JSON、也不是合法 UTF-8）裡的路徑也算引用
                let badRef = make("badref", date: old)
                var badData = Data([0xFF, 0xFE, 0x00]); badData.append(Data(badRef.appendingPathComponent("a.png").path.utf8))
                try? badData.write(to: state.appendingPathComponent("drafts/c2.json.bad-20260101-000000-abc123"))
                let n = TerminalPane.cleanDropFolder(folder: folder, stateDir: state)
                try? "removed=\(n)\nunref_gone=\(!fm.fileExists(atPath: unref.path))\nref_kept=\(fm.fileExists(atPath: ref.path))\nbad_ref_kept=\(fm.fileExists(atPath: badRef.path))\nfresh_kept=\(fm.fileExists(atPath: fresh.path))\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --git-safety-probe 輸出檔：(1) 專案設定的 filter 不會被背景 git 執行 (2) 逾時會連忽略 TERM 的 git 和它的子程序一起砍掉（假 git，用暫存資料夾）
        if let i = args.firstIndex(of: "--git-safety-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                let fm = FileManager.default
                let root = URL(fileURLWithPath: (out as NSString).deletingLastPathComponent).appendingPathComponent("gitsafety", isDirectory: true)
                try? fm.removeItem(at: root); try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                func sh(_ cmd: String, cwd: URL? = nil) {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]; p.currentDirectoryURL = cwd
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
                }
                // (1) 專案設定的 filter（已知限制：擋不住，只記錄 filter_ran 供參考）；大小相同、內容不同的修改要被偵測到（changed_attr=1、changed_info=1）
                let repo = root.appendingPathComponent("repo", isDirectory: true), marker = root.appendingPathComponent("pwned").path
                let repo2 = root.appendingPathComponent("repo2", isDirectory: true), crlf = root.appendingPathComponent("crlf", isDirectory: true)
                for d in [repo, repo2, crlf] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
                let ident = "git -c user.email=a@b -c user.name=n commit -qm x"
                sh("git init -q . && printf 'aaaa\\n' > a && echo '* filter=evil' > .gitattributes && git config filter.evil.clean 'touch \(marker); cat' && git add a .gitattributes && \(ident) && rm -f \(marker) && sleep 1 && printf 'bbbb\\n' > a", cwd: repo)
                sh("git init -q . && printf 'aaaa\\n' > a && git add a && \(ident) && echo 'a filter=evil' > .git/info/attributes && git config filter.evil.clean 'cat' && sleep 1 && printf 'bbbb\\n' > a", cwd: repo2)
                // CRLF 提交、* text eol=crlf 的 repo：不能因為我們加的選項多出假的變更
                sh("git init -q . && git config core.autocrlf false && printf 'x\\r\\ny\\r\\n' > a && echo '* text eol=crlf' > .gitattributes && git add a .gitattributes && \(ident)", cwd: crlf)
                let info = SessionActivity.readGit(repo.path), info2 = SessionActivity.readGit(repo2.path), infoCrlf = SessionActivity.readGit(crlf.path)
                let filterRan = fm.fileExists(atPath: marker)
                // (2) 逾時整群砍
                let fake = root.appendingPathComponent("fake-git").path
                try? "#!/bin/sh\ntrap '' TERM\n(sleep 7771) &\nsleep 7772\n".write(toFile: fake, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
                GitProcess.path = fake; SessionActivity.gitTimeout = 2
                let t0 = Date()
                let r = SessionActivity.readGit(repo.path)
                let secs = Date().timeIntervalSince(t0)
                // (3) git 不存在：perl exec 失敗要回 nil，不能回「成功但空」的結果
                GitProcess.path = "/nonexistent/git"
                let missing = SessionActivity.readGit(repo.path)
                GitProcess.path = "/usr/bin/git"
                // (4) 右欄的 RPShell.run 也整群砍（忽略 TERM 的 sh 加背景子程序）
                let t1 = Date()
                let rr = RPShell.run("/bin/sh", ["-c", "trap '' TERM; (sleep 7773) & sleep 7774"], timeout: 2)
                let rpSecs = Date().timeIntervalSince(t1)
                Thread.sleep(forTimeInterval: 1)
                let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-ax", "-o", "command="]
                let pipe = Pipe(); ps.standardOutput = pipe; try? ps.run()
                let psOut = pipe.fileHandleForReading.readDataToEndOfFile(); ps.waitUntilExit()      // 先讀完再等結束，輸出多時才不會互等
                let left = String(decoding: psOut, as: UTF8.self).components(separatedBy: "\n").filter { $0.contains("sleep 7771") || $0.contains("sleep 7772") || $0.contains("sleep 7773") || $0.contains("sleep 7774") }.count
                try? "info_ok=\(info != nil)\nchanged_attr=\(info?.changed ?? -1)\nchanged_info=\(info2?.changed ?? -1)\ncrlf_changed=\(infoCrlf?.changed ?? -1)\nfilter_ran=\(filterRan)\ntimeout_nil=\(r == nil)\ntimeout_fast=\(secs < 8)\nmissing_git_nil=\(missing == nil)\nrpshell_timed_out=\(rr.timedOut)\nrpshell_fast=\(rpSecs < 8)\nleftover=\(left)\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --schedule-summary-probe 輸出檔：每週排程的 weekdays 含 0、負數、8 以上時，summary 不能崩潰（舊版 names[($0-1)%7] 對 0 越界 trap）
        if let i = args.firstIndex(of: "--schedule-summary-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                func sum(_ w: [Int]) -> String { var s = WakeSchedule(conversation: UUID(), text: "x"); s.frequency = "weekly"; s.weekdays = w; return s.summary }
                let lines = ["zero=\(sum([0]))", "neg=\(sum([-3, 2]))", "eight=\(sum([8, 1]))", "empty=\(sum([]))", "normal=\(sum([7, 1]))"]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --carry-time-probe "紀錄檔:輸出檔"：量換模型交接在主執行緒要花多久（只讀檔尾）對照整份讀；再等背景補完全文檔，量全文檔是否完整
        if let i = args.firstIndex(of: "--carry-time-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let url = URL(fileURLWithPath: String(parts[0])), out = String(parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                    let t0 = Date()
                    let sid = UUID()
                    let note = ModelCarry.note(from: url, session: sid, model: "測試模型", limit: 6000, canRead: true)
                    let syncSecs = Date().timeIntervalSince(t0)
                    let doc = ModelCarry.dir.appendingPathComponent(sid.uuidString.lowercased() + ".md")
                    let firstDoc = (try? String(contentsOf: doc, encoding: .utf8)) ?? ""
                    // 同一份檔整份解析（舊作法）的耗時，在背景量，免得卡住自己
                    DispatchQueue.global().async {
                        let t1 = Date()
                        let all = ModelCarry.turns(url)
                        let fullSecs = Date().timeIntervalSince(t1)
                        var waited = 0.0
                        var finalDoc = firstDoc
                        while waited < 120 {
                            finalDoc = (try? String(contentsOf: doc, encoding: .utf8)) ?? ""
                            if !finalDoc.contains("這是先寫的檔尾版") { break }
                            Thread.sleep(forTimeInterval: 0.5); waited += 0.5
                        }
                        let lines = ["size=\(size)", String(format: "sync_secs=%.3f", syncSecs), String(format: "full_parse_secs=%.3f", fullSecs),
                                     "note_nil=\(note == nil)", "note_chars=\(note?.count ?? 0)",
                                     "first_doc_partial=\(firstDoc.contains("這是先寫的檔尾版"))", "first_doc_chars=\(firstDoc.count)",
                                     "final_doc_partial=\(finalDoc.contains("這是先寫的檔尾版"))", "final_doc_chars=\(finalDoc.count)",
                                     "full_turns=\(all.count)", "note_has_last=\(all.last.map { note?.contains(String($0.text.prefix(20))) ?? false } ?? false)"]
                        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --carry-race-probe "A:B:長行:輸出檔"：A（大檔）→ B（小檔）同一個聊天室連換兩次，等背景跑完，全文檔必須是 B 的（不能被 A 的完整版蓋回）；
        // 長行檔＝最後一行超過檔尾窗的檔，交接不能回 nil
        if let i = args.firstIndex(of: "--carry-race-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            if parts.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let sid = UUID()
                    let nA = ModelCarry.note(from: URL(fileURLWithPath: parts[0]), session: sid, model: "甲", limit: 6000, canRead: true)
                    let nB = ModelCarry.note(from: URL(fileURLWithPath: parts[1]), session: sid, model: "乙", limit: 6000, canRead: true)
                    let nLong = ModelCarry.note(from: URL(fileURLWithPath: parts[2]), session: UUID(), model: "丙", limit: 6000, canRead: true)
                    DispatchQueue.global().async {
                        Thread.sleep(forTimeInterval: 12)      // 背景補全文的工作全部跑完
                        let doc = (try? String(contentsOf: ModelCarry.dir.appendingPathComponent(sid.uuidString.lowercased() + ".md"), encoding: .utf8)) ?? ""
                        let lines = ["noteA_nil=\(nA == nil)", "noteB_nil=\(nB == nil)", "long_nil=\(nLong == nil)", "long_has_text=\(nLong?.contains("LONGFIRST") ?? false)",
                                     "doc_has_B=\(doc.contains("BBBB"))", "doc_has_A=\(doc.contains("AAAA"))"]
                        try? lines.joined(separator: "\n").write(toFile: parts[3], atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --decode-compat-probe 輸出檔：目前格式的 sprint.json／schedules.json 單筆要讀得懂（有人新增非 Optional 欄位、舊檔缺鍵會整份讀不出來時，這裡先失敗）
        if let i = args.firstIndex(of: "--decode-compat-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                func enc<T: Encodable>(_ v: T) -> Data { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return (try? e.encode(v)) ?? Data() }
                func dec<T: Decodable>(_ t: T.Type, _ d: Data) -> Bool { let x = JSONDecoder(); x.dateDecodingStrategy = .iso8601; return (try? x.decode(t, from: d)) != nil }
                // 把現在的實例編成 JSON，再逐一拿掉一個鍵（模擬舊版檔案沒有這個鍵）：缺鍵讀不懂的列出來
                func missing<T: Codable>(_ v: T, as t: T.Type) -> [String] {
                    let base = enc(v)
                    guard let o = try? JSONSerialization.jsonObject(with: base) as? [String: Any] else { return ["（編不出 JSON）"] }
                    var bad: [String] = []
                    for k in o.keys.sorted() {
                        var o2 = o; o2[k] = nil
                        if let d = try? JSONSerialization.data(withJSONObject: o2), !dec(t, d) { bad.append(k) }
                    }
                    return bad
                }
                let ws = WakeSchedule(conversation: UUID(), text: "x")
                let sp = SprintState()
                let lines = ["wake_roundtrip=\(dec(WakeSchedule.self, enc(ws)))", "sprint_roundtrip=\(dec(SprintState.self, enc(sp)))",
                             "wake_missing_fail=\(missing(ws, as: WakeSchedule.self).joined(separator: ","))",
                             "sprint_missing_fail=\(missing(sp, as: SprintState.self).joined(separator: ","))"]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --env-probe 輸出檔：測試實例給子程序的 CODENV_* 環境變數、主視窗在哪台螢幕（--test-screen 測試用）
        if let i = args.firstIndex(of: "--env-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                var lines = Workspace.environment().filter { $0.hasPrefix("CODENV_") }.sorted()
                if let w = self?.main.window {
                    let c = NSPoint(x: w.frame.midX, y: w.frame.midY)
                    let sc = NSScreen.screens.first { $0.frame.contains(c) }
                    lines.append("window_screen=\(sc?.localizedName ?? "?")")
                    lines.append("window_inside_visible=\(sc.map { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(w.frame) } ?? false)")
                    lines.append("window_visible=\(w.isVisible)")
                }
                lines.append("screens=\(NSScreen.screens.map(\.localizedName).joined(separator: "|"))")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --progress-fuzz：直接呼叫 PetTimers.handle 塞 NaN／無限／超大數字（不發全域通知，不碰真桌寵），沒崩潰就把結果寫進檔案
        if let i = args.firstIndex(of: "--progress-fuzz"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let bad: [Double] = [.nan, .infinity, -.infinity, 1e30, -1e30, 9.3e18, 5]
                for (n, v) in bad.enumerated() {
                    PetTimers.shared.handle(["cmd": "start", "id": "fz\(n)", "label": "x", "total": NSNumber(value: v), "eta": NSNumber(value: v)])
                    PetTimers.shared.handle(["cmd": "update", "id": "fz\(n)", "done": NSNumber(value: v), "total": NSNumber(value: v)])
                    PetTimers.shared.handle(["cmd": "cancel", "id": "fz\(n)"])
                }
                // 走到 items()：eta 1e30 繞過 handle 的 clamp 直接進 model，畫面重畫算「剩幾分鐘」不能 trap
                for (n, v) in bad.enumerated() {
                    PetTimers.shared.inject(id: "it\(n)", label: "x", eta: v)
                    _ = PetTimers.shared.model.items()
                    PetTimers.shared.handle(["cmd": "cancel", "id": "it\(n)"])
                }
                try? "ok \(bad.count)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --commander-op "秒數:new:名稱:新分組名:資料夾[:single|multi]" 或 "秒數:del:名稱"：不經表單直接呼叫新增／刪除總指揮（結果寫 EventLog）
        for (i, a) in args.enumerated() where a == "--commander-op" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store else { return }
                if parts[1] == "new", parts.count >= 5 {
                    var err: String?
                    let req = Store.NewCommander(name: parts[2], groups: [], newGroupName: parts[3].isEmpty ? nil : parts[3], newGroupFolder: parts[4], kind: parts.count > 5 && !parts[5].isEmpty ? parts[5] : nil)
                    let id = st.createCommander(req, error: &err)
                    EventLog.log("測試", "新增總指揮 \(parts[2])：\(id?.uuidString ?? "失敗 \(err ?? "")")")
                } else if parts[1] == "del", let s = st.sessions.first(where: { $0.area == nil && $0.groups != nil && $0.name == parts[2] }) {
                    st.deleteCommander(s.id)
                    EventLog.log("測試", "刪除總指揮 \(parts[2])")
                }
            }
        }
        // --cli-path-dump 檔案：把 CLITools 找到的三支工具路徑與給聊天室的 PATH 寫成檔（搭 CODENV_LOCAL_BIN 測家目錄沒裝的情況）
        for (i, a) in args.enumerated() where a == "--cli-path-dump" && i + 1 < args.count && args.contains("--state-dir") {
            let out = CLITools.names.map { "\($0)=\(CLITools.path($0) ?? "nil")" }.joined(separator: "\n") + "\nPATH=\(CLITools.pathEntries(home: NSHomeDirectory()))\nsearchScript=\(SearchIndexClient.script.path)\n"
            try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        // --sprint-card-snapshot "秒數:檔案前綴"：把右欄的衝刺卡片畫成圖片（前綴-idle.png、前綴-running.png；running 用假狀態，只寫測試實例的 sprint.json）
        for (i, a) in args.enumerated() where a == "--sprint-card-snapshot" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                func shot(_ suffix: String) {
                    let host = NSHostingView(rootView: SprintCard().environment(\.uiScale, UIScale.shared.f).frame(width: 330).padding(8).background(Color(nsColor: .windowBackgroundColor)))
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1] + "-" + suffix + ".png"))
                }
                shot("idle")
                SprintStore.shared.update { s in
                    s.phase = "running"; s.convTitle = "codenv_1"; s.startedAt = Date().addingTimeInterval(-3600)
                    s.watchLabel = "5 小時"; s.targetReset = Date().addingTimeInterval(95 * 60)
                    s.goal = "把對話搜尋的索引改成增量更新，並補上測試；順便清掉舊的暫存檔"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shot("running") }
            }
        }
        // --agy-notice-snapshot "秒數:檔案.png"：把 agy 預設開啟的提醒卡片畫成圖片（不顯示真的浮動卡片）
        for (i, a) in args.enumerated() where a == "--agy-notice-snapshot" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let host = NSHostingView(rootView: AgyNoticeCard(onKnow: {}, onSettings: {}).background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            }
        }
        // --commander-form-snapshot "秒數:檔案.png"：把「新增總指揮」表單畫成圖片（表單是 sheet，--snapshot 拍不到）
        for (i, a) in args.enumerated() where a == "--commander-form-snapshot" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store else { return }
                let host = NSHostingView(rootView: CommanderCreateForm(store: st).background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            }
        }
        // --snapshot "秒數:檔案.png"：幾秒後把整個視窗內容畫成圖片（視窗被蓋住也拍得到最新畫面）
        for (i, a) in args.enumerated() where a == "--snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let v = self?.main.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        // --settings-snapshot "秒數:頁:檔案"：打開設定視窗（頁＝windows、chat、appearance、pet、keys、local、schedules、data）拍成 PNG。測英文介面有沒有漏翻用
        for (i, a) in args.enumerated() where a == "--settings-snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            let tab = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                appDefaults.set(tab, forKey: "settingsTab")      // 測試實例的偏好，不是正式的
                self?.showSettings()
                guard let w = self?.settings?.window else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[2]))
                }
            }
        }
        // --web-snapshot "秒數:檔案"：目前聊天室的網頁拍成 PNG（背景測試時 screencapture 拍不到網頁內容）
        for (i, a) in args.enumerated() where a == "--web-snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.snapshotWeb(to: path)
            }
        }
        // --dump "秒數:檔案"：幾秒後把目前那格的尺寸和畫面文字寫進檔案
        for (i, a) in args.enumerated() where a == "--dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                var out = "pane \(p.frame) terminal \(p.terminal.frame)\n"
                for v in p.subviews { out += "  \(type(of: v)) \(v.frame) hidden \(v.isHidden) sub \(v.subviews.map { "\(type(of: $0))\($0.frame)\($0.isHidden ? "隱" : "")" })\n" }
                p.terminal.withTerminalPublic { t in
                    out += "cols \(t.cols) rows \(t.rows) yDisp \(t.buffer.yDisp)\n"
                    for r in 0..<t.rows { out += (t.getLine(row: r)?.translateToString(trimRight: true) ?? "") + "\n" }
                }
                try? out.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        for (i, a) in args.enumerated() where a == "--send" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\e", with: "\u{1b}")
                .replacingOccurrences(of: "^X", with: "\u{18}").replacingOccurrences(of: "^S", with: "\u{13}")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                p.terminal.send(txt: text)
            }
        }

        // --codelab-big5-probe "秒數:Big5檔路徑:另一個檔路徑:輸出檔"：開 Big5 檔（不改）→ 換開另一個檔，Big5 檔的位元組不能變（不能被悄悄存成 UTF-8）
        for (i, a) in args.enumerated() where a == "--codelab-big5-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), parts[1].hasPrefix("/"), parts[2].hasPrefix("/"), parts[3].hasPrefix("/") else { continue }
            let big5Path = parts[1], otherPath = parts[2], outFile = parts[3]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane else {
                    try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8); return
                }
                if p.codeLab == nil { p.attachCodeLab(directory: (big5Path as NSString).deletingLastPathComponent, key: f.uuidString) }
                guard let lab = p.codeLab else { try? "error=無法建立程式碼區\n".write(toFile: outFile, atomically: true, encoding: .utf8); return }
                self.recoveryProbeLabs.append(lab)
                let before = FileManager.default.contents(atPath: big5Path) ?? Data()
                func pollReady(attempt: Int = 0, done: @escaping () -> Void) {
                    lab.testAction("js=typeof cl !== 'undefined'") { res in
                        if res.contains("true") || res.contains("1") { done() }
                        else if attempt < 50 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pollReady(attempt: attempt + 1, done: done) } }
                        else { try? "error=編輯器初始化超時\n".write(toFile: outFile, atomically: true, encoding: .utf8) }
                    }
                }
                pollReady {
                    lab.open(big5Path)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        lab.testAction("switch=" + otherPath) { _ in }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let after = FileManager.default.contents(atPath: big5Path) ?? Data()
                            try? "big5_intact=\(after == before)\nbefore_bytes=\(before.count)\nafter_bytes=\(after.count)\ncurrent_file=\(lab.file ?? "nil")\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
        }
        // --codelab-delayed-save-probe "秒數:檔A路徑:檔B路徑:輸出檔"
        // 考卷 C14 規格：CodeLab 開檔 A、改開檔 B 之後才收到網頁送來 path=A 的 save 訊息，B 的 bytes 不能變、A 也不能被寫成 B 的內容
        for (i, a) in args.enumerated() where a == "--codelab-delayed-save-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]),
                  parts[1].hasPrefix("/"), parts[2].hasPrefix("/"), parts[3].hasPrefix("/") else { continue }
            let pathA = parts[1], pathB = parts[2], outFile = parts[3]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let f = self.store.currentWindow?.focused,
                      let p = self.workspace.panes[f] as? ChatPane else {
                    try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                let projDir = (pathA as NSString).deletingLastPathComponent
                if p.codeLab == nil {
                    p.attachCodeLab(directory: projDir, key: f.uuidString)
                }
                guard let lab = p.codeLab else {
                    try? "error=無法建立程式碼區\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                self.recoveryProbeLabs.append(lab)

                let initialA = FileManager.default.contents(atPath: pathA) ?? Data()
                let initialB = FileManager.default.contents(atPath: pathB) ?? Data()

                func pollReady(attempt: Int = 0, done: @escaping () -> Void) {
                    lab.testAction("js=typeof cl !== 'undefined'") { res in
                        if res.contains("true") || res.contains("1") {
                            done()
                        } else if attempt < 50 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                pollReady(attempt: attempt + 1, done: done)
                            }
                        } else {
                            try? "error=編輯器初始化超時\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        }
                    }
                }

                pollReady {
                    // 1. 開檔 A
                    lab.open(pathA)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        // 記下開 A 時網頁的 token：真實的遲到訊息帶的是這個
                        lab.testAction("js=window.__tokA = cl.text().token") { _ in }
                        // 2. 改開檔 B
                        lab.open(pathB)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            // 3. 此時目前檔案為 B。送來 path=A 的遲到 save 訊息
                            // (1) 真實情況：path=A、帶開 A 時的 token
                            let scriptWithOldPath = "window.webkit.messageHandlers.codelab.postMessage({ type: 'save', path: \(Self.jsEscapeString(pathA)), text: '// HACKED DELAYED SAVE FROM A\\n', token: window.__tokA });"
                            lab.testAction("js=" + scriptWithOldPath) { _ in }
                            // (2) path=A 但帶現在（B）的 token：只有「路徑要等於目前檔案」這道檢查擋得住（593aaf7 的修正本身）
                            let scriptPathOnly = "window.webkit.messageHandlers.codelab.postMessage({ type: 'save', path: \(Self.jsEscapeString(pathA)), text: '// HACKED SAVE PATH-ONLY\\n', token: cl.text().token });"
                            lab.testAction("js=" + scriptPathOnly) { _ in }

                            // 4. 同時測試不帶 path 的舊式 save（593aaf7 修正前沒有 path）
                            let scriptNoPath = "window.webkit.messageHandlers.codelab.postMessage({ type: 'save', text: '// HACKED SAVE WITHOUT PATH\\n' });"
                            lab.testAction("js=" + scriptNoPath) { _ in }

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                let curA = FileManager.default.contents(atPath: pathA) ?? Data()
                                let curB = FileManager.default.contents(atPath: pathB) ?? Data()
                                let bIntact = (curB == initialB)
                                let aIntact = (curA == initialA)
                                let aNotB = (curA != curB)
                                let curFile = lab.file ?? "nil"
                                let out = "b_intact=\(bIntact)\na_intact=\(aIntact)\na_not_b=\(aNotB)\ncurrent_file=\(curFile)\n"
                                try? out.write(toFile: outFile, atomically: true, encoding: .utf8)
                            }
                        }
                    }
                }
            }
        }

        // --codelab-focus-keys-probe "秒數:輸出檔"
        // 考卷 C15 規格：焦點在程式碼編輯器時 Tab、/、⌃C、⌃Enter 留在編輯器；焦點在聊天輸入框時照聊天行為（修正 d0b1f06）
        for (i, a) in args.enumerated() where a == "--codelab-focus-keys-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), parts[1].hasPrefix("/") else { continue }
            let outFile = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let f = self.store.currentWindow?.focused,
                      let p = self.workspace.panes[f] as? ChatPane,
                      let w = self.main.window else {
                    try? "error=找不到聊天格或主視窗\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                let projDir = self.store.project(self.store.conversation(f)?.projectID ?? UUID())?.path ?? "/tmp"
                if p.codeLab == nil {
                    p.attachCodeLab(directory: projDir, key: f.uuidString)
                }
                guard let lab = p.codeLab else {
                    try? "error=無法建立程式碼區\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                self.recoveryProbeLabs.append(lab)

                func pollReady(attempt: Int = 0, done: @escaping () -> Void) {
                    lab.testAction("js=typeof cl !== 'undefined'") { res in
                        if res.contains("true") || res.contains("1") {
                            done()
                        } else if attempt < 50 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                pollReady(attempt: attempt + 1, done: done)
                            }
                        } else {
                            try? "error=編輯器初始化超時\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        }
                    }
                }

                pollReady {
                    guard let editorWeb = Self.find(WKWebView.self, in: lab) else {
                        try? "error=找不到編輯器網頁\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        return
                    }
                    func chatWebViews(_ v: NSView) -> [WKWebView] {
                        v === lab ? [] : (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(chatWebViews)
                    }
                    guard let chatWeb = chatWebViews(p).first else {
                        try? "error=找不到聊天網頁\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        return
                    }
                    let inputTV = p.inputBar.textView
                    let inputBar = p.inputBar
                    var res: [String: Bool] = [:]

                    func inEditor() -> Bool {
                        guard let v = w.firstResponder as? NSView else { return false }
                        return v === editorWeb || v.isDescendant(of: editorWeb) || v.isDescendant(of: lab)
                    }

                    // 步驟 1：焦點在編輯器，測 Tab
                    w.makeFirstResponder(editorWeb)
                    lab.testAction("js=cl.focus()") { _ in }
                    inputTV.string = ""
                    inputBar.suggestion = "灰字建議"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        Self.dispatchKeyEvent(code: 48, chars: "\t", window: w)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            res["editor_tab"] = inEditor() && inputTV.string.isEmpty

                            // 步驟 2：焦點在編輯器，測 /
                            w.makeFirstResponder(editorWeb)
                            lab.testAction("js=cl.focus()") { _ in }
                            inputTV.string = ""
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                Self.dispatchKeyEvent(code: 44, chars: "/", window: w)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    res["editor_slash"] = inEditor() && (w.firstResponder !== inputTV)

                                    // 步驟 3：焦點在編輯器，測 ⌃C
                                    w.makeFirstResponder(editorWeb)
                                    lab.testAction("js=cl.focus()") { _ in }
                                    var chatInterrupted = false
                                    let prevOnStop = inputBar.onStop
                                    inputBar.onStop = { chatInterrupted = true; prevOnStop?() }
                                    inputBar.busy = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                        Self.dispatchKeyEvent(code: 8, chars: "\u{03}", unmodChars: "c", mods: .control, window: w)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                            res["editor_ctrl_c"] = inEditor() && !chatInterrupted
                                            inputBar.busy = false
                                            inputBar.onStop = prevOnStop

                                            // 步驟 4：焦點在編輯器，測 ⌃Enter
                                            w.makeFirstResponder(editorWeb)
                                            lab.testAction("js=cl.focus()") { _ in }
                                            var chatSentNow = false
                                            let prevOnSendQueued = inputBar.onSendQueuedNow
                                            inputBar.onSendQueuedNow = { chatSentNow = true; prevOnSendQueued?() }
                                            inputTV.string = ""
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                Self.dispatchKeyEvent(code: 36, chars: "\r", unmodChars: "\r", mods: .control, window: w)
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                    res["editor_ctrl_enter"] = inEditor() && !chatSentNow
                                                    inputBar.onSendQueuedNow = prevOnSendQueued

                                                    // 步驟 5：正向對照——焦點在聊天內容，測 Tab（跳回輸入框並採用灰字建議）
                                                    w.makeFirstResponder(chatWeb)
                                                    inputTV.string = ""
                                                    inputBar.suggestion = "灰字建議"
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                        Self.dispatchKeyEvent(code: 48, chars: "\t", window: w)
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                            let adopted = (inputTV.string == "灰字建議")
                                                            let tvFocused = (w.firstResponder === inputTV)
                                                            res["chat_tab"] = tvFocused && adopted

                                                            // 步驟 6：正向對照——焦點在聊天內容，測 /（跳回輸入框）
                                                            w.makeFirstResponder(chatWeb)
                                                            inputTV.string = ""
                                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                Self.dispatchKeyEvent(code: 44, chars: "/", window: w)
                                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                    res["chat_slash"] = (w.firstResponder === inputTV)

                                                                    // 步驟 7：正向對照——焦點在聊天內容，測 ⌃C（由聊天攔截觸發中斷）
                                                                    w.makeFirstResponder(chatWeb)
                                                                    var chatInterrupted2 = false
                                                                    let prevOnStop2 = inputBar.onStop
                                                                    inputBar.onStop = { chatInterrupted2 = true; prevOnStop2?() }
                                                                    inputBar.busy = true
                                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                        Self.dispatchKeyEvent(code: 8, chars: "\u{03}", unmodChars: "c", mods: .control, window: w)
                                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                            res["chat_ctrl_c"] = chatInterrupted2
                                                                            inputBar.busy = false
                                                                            inputBar.onStop = prevOnStop2

                                                                            // 步驟 8：正向對照——焦點在聊天內容，測 ⌃Enter（由聊天攔截觸發馬上插話）
                                                                            w.makeFirstResponder(chatWeb)
                                                                            var chatSentNow2 = false
                                                                            let prevOnSendQueued2 = inputBar.onSendQueuedNow
                                                                            inputBar.onSendQueuedNow = { chatSentNow2 = true; prevOnSendQueued2?() }
                                                                            inputTV.string = ""
                                                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                                Self.dispatchKeyEvent(code: 36, chars: "\r", unmodChars: "\r", mods: .control, window: w)
                                                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                                    res["chat_ctrl_enter"] = chatSentNow2
                                                                                    inputBar.onSendQueuedNow = prevOnSendQueued2

                                                                                    let out = [
                                                                                        "editor_tab=\(res["editor_tab"] ?? false)",
                                                                                        "editor_slash=\(res["editor_slash"] ?? false)",
                                                                                        "editor_ctrl_c=\(res["editor_ctrl_c"] ?? false)",
                                                                                        "editor_ctrl_enter=\(res["editor_ctrl_enter"] ?? false)",
                                                                                        "chat_tab=\(res["chat_tab"] ?? false)",
                                                                                        "chat_slash=\(res["chat_slash"] ?? false)",
                                                                                        "chat_ctrl_c=\(res["chat_ctrl_c"] ?? false)",
                                                                                        "chat_ctrl_enter=\(res["chat_ctrl_enter"] ?? false)"
                                                                                    ].joined(separator: "\n") + "\n"
                                                                                    try? out.write(toFile: outFile, atomically: true, encoding: .utf8)
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 測試用：把「C-a」「|」「h」這種寫法變成真的按鍵事件丟進 App
    /// 背景測試時自己送的事件要等「下一個事件」來才會被處理：補一個沒作用的事件把它們推出去
    static func flushEvents(_ w: NSWindow) {
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(e, atStart: false) }
    }

    /// 在畫面元件樹裡找第一個某種元件（測試用）
    static func find<T: NSView>(_ t: T.Type, in v: NSView?) -> T? {
        guard let v else { return nil }
        if let x = v as? T { return x }
        for c in v.subviews { if let x = find(t, in: c) { return x } }
        return nil
    }

    static func postKey(_ token: String, window: NSWindow) {
        defer { flushEvents(window) }
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, "[": 33, "]": 30, "`": 50]
        let shifted: [Character: Character] = ["|": "\\", "&": "7", "$": "4", "(": "9", ")": "0", "?": "/"]
        var mods: NSEvent.ModifierFlags = []
        var ch = Character(token.last.map(String.init) ?? " ")
        if token.hasPrefix("C-") { mods.insert(.control) }
        if token.hasPrefix("D-") { mods.insert(.command) }   // D-1＝⌘ 1（測 Window 切換）
        if token.contains("S-") { mods.insert(.shift) }      // D-S-z＝⌘ ⇧ Z
        if token == "Esc" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        // 特殊鍵：Tab、↑、↓（測 / 選單）、Ret＝Enter（測程式碼區的 cin）
        let special: [String: (UInt16, String)] = ["Tab": (48, "\t"), "Down": (125, "\u{F701}"), "Up": (126, "\u{F700}"), "Left": (123, "\u{F702}"), "Right": (124, "\u{F703}"), "BS": (51, "\u{7F}"), "Ret": (36, "\r"), "F3": (99, "\u{F706}"), "F4": (118, "\u{F707}"), "F5": (96, "\u{F708}"), "F6": (97, "\u{F709}")]
        // 方向鍵可以加 C-（⌃ ←，測 ⌃ A 之後 ⌃ 沒放開）、D-（⌘ ↑，測輸入框跳到最前）
        let arrowMod = (token.hasPrefix("C-") || token.hasPrefix("D-")) && ["Left", "Right", "Up", "Down"].contains(String(token.dropFirst(2)))
        if let (code, chars) = special[arrowMod ? String(token.dropFirst(2)) : token] {
            var flags: NSEvent.ModifierFlags = code >= 123 && code <= 126 ? [.function, .numericPad] : (code == 96 || code == 97 ? [.function] : [])
            if arrowMod { flags.insert(token.hasPrefix("C-") ? .control : .command) }
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "C-Ret" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "D-S-Ret" {   // ⌘ ⇧ Enter（測學 Ghostty 的放大這格）
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "D-Ret" {   // ⌘ Enter（測問答卡片「其他」欄送出）
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "M-Up" || token == "M-Down" {   // ⌘ ↑／⌘ ↓
            let up = token == "M-Up", ch = up ? "\u{F700}" : "\u{F701}"
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: up ? 126 : 125)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "S-Tab" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{19}", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        var shown = String(ch)
        if mods.contains(.shift), ch.isLetter { shown = shown.uppercased() }   // 真的鍵盤按 ⌘ ⇧ Z 送的是大寫 Z
        if let base = shifted[ch] { mods.insert(.shift); ch = base }
        guard let code = codes[ch] else { return }
        if mods.contains(.control) { shown = String(UnicodeScalar(UInt8(ch.asciiValue! & 0x1f))) }
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: shown,
                                 charactersIgnoringModifiers: mods.contains(.shift) ? shown : String(ch), isARepeat: false, keyCode: code)
        if let e { NSApp.postEvent(e, atStart: false) }
    }

    /// App 內部直接派送按鍵事件（不用 CGEvent，背景測試不搶前景、不需輔助取用權限）
    static func dispatchKeyEvent(code: UInt16, chars: String, unmodChars: String? = nil, mods: NSEvent.ModifierFlags = [], window: NSWindow) {
        let unmod = unmodChars ?? chars
        let e = NSEvent.keyEvent(with: .keyDown,
                                 location: .zero,
                                 modifierFlags: mods,
                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber,
                                 context: nil,
                                 characters: chars,
                                 charactersIgnoringModifiers: unmod,
                                 isARepeat: false,
                                 keyCode: code)
        if let e {
            NSApp.sendEvent(e)
            flushEvents(window)
        }
    }

    /// 把字串安全轉成 JS 字串常數（含跳脫引號）
    static func jsEscapeString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }
}
