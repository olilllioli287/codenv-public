import AppKit
import Darwin
import Foundation

/// aa5770：閒置 CPU／關聯圖重畫量測掛鉤（只在 --state-dir 測試實例生效；輸出 JSON 不含私人內容）。
/// 參數：--idle-bench-probe <output.json> [--idle-bench-scenario idle|working|waiting] [--idle-bench-seconds N] [--idle-bench-warmup S]
extension AppDelegate {
    func installIdleBenchProbe(_ args: [String]) {
        guard let i = args.firstIndex(of: "--idle-bench-probe"), i + 1 < args.count, args.contains("--state-dir") else { return }
        func opt(_ name: String) -> String? {
            guard let k = args.firstIndex(of: name), k + 1 < args.count else { return nil }
            return args[k + 1]
        }
        let output = args[i + 1]
        let scenario = opt("--idle-bench-scenario") ?? "idle"
        let seconds = max(1, Double(opt("--idle-bench-seconds") ?? "20") ?? 20)
        let warmup = max(1, Double(opt("--idle-bench-warmup") ?? "8") ?? 8)
        ChatGraphView.forceAnimateForTest = true

        // collab.json（--state-dir 內）：100 筆 goals（時間戳含毫秒／不含毫秒交錯）、200 筆 findings、40 筆 items
        func writeFixtureCollab() {
            let isoMs = ISO8601DateFormatter(); isoMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
            func stamp(_ k: Int) -> String { let d = Date().addingTimeInterval(Double(-k * 600)); return k % 2 == 0 ? isoMs.string(from: d) : isoPlain.string(from: d) }
            var goals: [[String: Any]] = []
            for k in 0..<100 {
                var steps: [[String: Any]] = []
                for j in 0..<4 { steps.append(["id": "s\(k)-\(j)", "text": "假步驟\(j + 1)@codenv_\(j % 3 + 1)", "owner": "codenv_\(j % 3 + 1)", "state": j < k % 5 ? "done" : "todo", "at": stamp(k + j)]) }
                goals.append(["id": "g\(k)", "title": "假目標\(k + 1)", "done": "假完成條件", "status": k % 7 == 0 ? "proposed" : (k % 3 == 0 ? "done" : "active"), "by": "codenv_1", "at": stamp(k), "steps": steps])
            }
            var findings: [[String: Any]] = []
            for k in 0..<200 { findings.append(["id": "f\(k)", "by": "codenv_\(k % 3 + 1)", "at": stamp(k), "goal": "g\(k % 100)", "text": "假發現第 \(k + 1) 則", "files": ["a.swift", "b.swift"]]) }
            var items: [[String: Any]] = []
            for k in 0..<40 { items.append(["id": "i\(k)", "col": ["locked", "deliver", "verify", "blocked", "done"][k % 5], "text": "假登記\(k + 1)", "by": "codenv_\(k % 3 + 1)", "at": stamp(k)]) }
            let o: [String: Any] = ["goals": goals, "findings": findings, "items": items]
            if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: CollabBoardModel.todoFile, options: .atomic) }
        }
        // F3 驗證：--idle-bench-bad-collab <秒> ＝ 啟動時 collab.json 是壞的（不是合法 JSON），該秒數後換成合法 fixture，
        // 之後每 0.5 秒輪詢協作板 goals，輸出 <out>.collab.json：{goalsBefore, goalsAfter, appearAfterSeconds(null=60 秒內沒出現)}
        if let k = args.firstIndex(of: "--idle-bench-bad-collab"), k + 1 < args.count, let swapAt = Double(args[k + 1]) {
            try? "{ 這不是合法 JSON".write(to: CollabBoardModel.todoFile, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + swapAt) {
                let before = CollabBoardModel.shared.goals.count
                let t0 = ProcessInfo.processInfo.systemUptime
                writeFixtureCollab()
                var appeared: Double? = nil
                func poll() {
                    let el = ProcessInfo.processInfo.systemUptime - t0
                    if CollabBoardModel.shared.goals.count > 0 { appeared = el }
                    if appeared != nil || el > 60 {
                        var o: [String: Any] = ["goalsBefore": before, "goalsAfter": CollabBoardModel.shared.goals.count]
                        if let a = appeared { o["appearAfterSeconds"] = (a * 100).rounded() / 100 } else { o["appearAfterSeconds"] = NSNull() }
                        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: output + ".collab.json"), options: .atomic) }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                }
                poll()
            }
        } else {
            writeFixtureCollab()
        }
        // F1 驗證：--idle-bench-hide-show <秒> ＝ fixture 建好後那個秒數把右欄關聯圖切成清單再切回來
        let hideShowAt: Double? = args.firstIndex(of: "--idle-bench-hide-show").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }

        func cpuSeconds(children: Bool = false) -> Double {
            var ru = rusage()
            getrusage(children ? RUSAGE_CHILDREN : RUSAGE_SELF, &ru)
            func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
            return s(ru.ru_utime) + s(ru.ru_stime)
        }
        func write(_ o: [String: Any]) {
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if self.store.projects.isEmpty { _ = self.store.addProject(path: self.store.directory.appendingPathComponent("idle-bench-project").path) }
            guard let pid = self.store.projects.first?.id else {
                write(["scenario": scenario, "error": "沒有 project，無法建立假資料"]); return
            }
            // 固定假資料：8 個總指揮 session（各有自己的群組層級＋區長／成員對話），共 40 個群組、約 150 段聊天室（全 idle）
            var ids: [UUID] = []
            var areas: [UUID] = []
            var sessionIDs: [UUID] = []
            let keep = self.store.selectedProject
            for si in 0..<8 {
                let root = self.store.addGroup(named: "假總指揮組\(si + 1)")
                var subs: [UUID] = []
                for k in 0..<4 { subs.append(self.store.addGroup(named: "假區\(si + 1)-\(k + 1)", parent: k < 2 ? root.id : subs[k - 2]).id) }
                areas.append(root.id); areas.append(contentsOf: subs)
                var chief = self.store.createConversation(in: pid)
                self.store.selectedProject = keep
                self.store.move(chief.id, toGroup: root.id)
                self.store.rename(chief.id, to: "假總指揮\(si + 1)", byUser: false)
                chief = self.store.conversation(chief.id) ?? chief
                ids.append(chief.id)
                for k in 0..<18 {
                    let c = self.store.createConversation(in: pid)
                    self.store.selectedProject = keep
                    self.store.move(c.id, toGroup: k % 5 == 0 ? root.id : subs[k % subs.count])
                    self.store.rename(c.id, to: "假聊天室\(si + 1)-\(k + 1)", byUser: false)
                    ids.append(c.id)
                }
                let w = WindowLayout(name: "1")
                var sl = SessionLayout(name: "假總指揮\(si + 1)", windows: [w], current: w.id)
                sl.area = self.store.areaKey
                sl.groups = [root.id]
                sl.chief = chief.id
                self.store.sessions.append(sl)
                sessionIDs.append(sl.id)
            }
            if let first = sessionIDs.first { self.store.selectSession(first) }
            // 10 份假紀錄檔（projects/<slug>/<session>.jsonl）：放前 10 段聊天室，含 cross-session-message 與 SendMessage
            var jsonlFiles = 0
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for c in ids.prefix(10).compactMap({ self.store.conversation($0) }) {
                let dir = CollabBoardModel.projectsRoot.appendingPathComponent(ConversationMover.slug(self.store.workingDirectory(for: c)))
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var lines: [String] = []
                for m in 0..<40 {
                    let ts = iso.string(from: Date().addingTimeInterval(Double(-3600 + m * 30)))
                    let peer = "假對象\(m % 3)"
                    func json(_ o: [String: Any]) -> String { String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? "{}" }
                    lines.append(json(["type": "attachment", "timestamp": ts, "attachment": ["prompt": "<cross-session-message from=\"sock\(m % 3)\" from-name=\"\(peer)\">\n假訊息第 \(m) 則\n</cross-session-message>"]]))
                    lines.append(json(["type": "assistant", "timestamp": ts, "message": ["content": [["type": "tool_use", "name": "SendMessage", "input": ["to": peer, "message": "假回覆第 \(m) 則"]]]]]))
                }
                let url = dir.appendingPathComponent(c.claudeSession.uuidString.lowercased() + ".jsonl")
                if (try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)) != nil { jsonlFiles += 1 }
            }
            let target = ids[3]
            switch scenario {
            case "working": self.store.status[target] = .working
            case "waiting": self.store.status[target] = .waiting
            default: break
            }
            self.main.window?.setContentSize(NSSize(width: 1400, height: 900))   // 固定視窗大小，讓截圖可跨版本逐像素比對
            RightPanelModel.shared.chatGraph = true
            self.main.showRightPanel(tab: .windows)
            if let at = hideShowAt {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { RightPanelModel.shared.chatGraph = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.8) { RightPanelModel.shared.chatGraph = true }
            }
            if let n = self.main.window?.windowNumber { try? String(n).write(toFile: output + ".win", atomically: true, encoding: .utf8) }

            DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { [weak self] in
                guard let self else { return }
                guard let gv = ChatGraphView.rightInstance else {
                    write(["scenario": scenario, "error": "找不到右欄關聯圖（ChatGraphView.rightInstance 為 nil）"]); return
                }
                let d0 = gv.diagnosticsForTest
                let cpu0 = cpuSeconds()
                let kid0 = cpuSeconds(children: true)
                let t0 = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self else { return }
                    let t1 = ProcessInfo.processInfo.systemUptime
                    let cpu1 = cpuSeconds()
                    let kid1 = cpuSeconds(children: true)
                    let d1 = gv.diagnosticsForTest
                    let window = t1 - t0
                    let boundsArea = max(1, Double(gv.bounds.width * gv.bounds.height))
                    func r(_ v: Double, _ k: Double) -> Double { (v * k).rounded() / k }
                    let selfCpu: Double = cpu1 - cpu0
                    let allCpu: Double = selfCpu + (kid1 - kid0)
                    let win: Double = max(0.001, window)
                    let delta: Int = d1.drawCount - d0.drawCount
                    var o: [String: Any] = [:]
                    o["scenario"] = scenario
                    o["canAnimate"] = gv.canAnimateForTest
                    o["windowVisible"] = gv.window?.isVisible ?? false
                    o["appActive"] = NSApp.isActive
                    o["occlusionVisible"] = gv.window?.occlusionState.contains(.visible) ?? false
                    o["windowSeconds"] = r(window, 100)
                    o["processTotalCpuPercent"] = r(allCpu / win * 100, 10)
                    o["avgCpuPercent"] = r(selfCpu / win * 100, 10)
                    o["drawCountDelta"] = delta
                    o["drawsPerSecond"] = r(Double(delta) / win, 10)
                    o["timerRunning"] = d1.timerRunning
                    o["dirtyRectAreaRatio"] = r(d1.lastDirtyRectArea / boundsArea, 1000)
                    o["conversations"] = ids.count
                    o["groups"] = areas.count
                    o["sessions"] = sessionIDs.count
                    o["jsonlFiles"] = jsonlFiles
                    // change 階段：改變一個節點（idle 情境改 working；其餘改標題），1 秒後 drawCount 至少 +1
                    let c0 = gv.diagnosticsForTest.drawCount
                    if scenario == "working" { self.store.rename(target, to: "改名後的聊天室", byUser: false) }
                    else { self.store.status[ids[5]] = .working }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        o["changeDrawCountDelta"] = gv.diagnosticsForTest.drawCount - c0
                        write(o)
                    }
                }
            }
        }
    }
}
