import Foundation
var sent: [[String: Any]] = []; var emitted: [[String: Any]] = []
func check(_ ok: Bool, _ name: String) { print(ok ? "PASS" : "FAIL", name); if !ok { failed = true } }
var failed = false
// ---- Codex
let sid = UUID()
let c = CodexBridge(session: sid, directory: "/tmp", model: "m")
c.send = { sent.append($0) }; c.emit = { emitted.append($0) }
try? FileManager.default.removeItem(at: c.transcriptURL)
c.start()
func lastID(_ m: String) -> Int { ((sent.last { $0["method"] as? String == m })?["id"] as? NSNumber)?.intValue ?? -1 }
c.incoming(["id": lastID("thread/start"), "result": ["thread": ["id": "T1"]]])
// 1. 使用者打 / 開頭（有 uuid）要送出；內部（沒 uuid）要吃掉
sent = []
c.outgoing(["type": "user", "message": ["role": "user", "content": "/effort high"]])
check(!sent.contains { $0["method"] as? String == "turn/start" }, "codex 內部 /effort 吃掉")
c.outgoing(["type": "user", "uuid": "U1", "message": ["role": "user", "content": "/Volumes/x/a.log 看一下"]])
check(sent.contains { $0["method"] as? String == "turn/start" }, "codex 使用者 / 開頭照送")
// 4. turn/start 錯誤要補 isReplay
emitted = []
c.incoming(["id": lastID("turn/start"), "error": ["message": "bad"]])
check(emitted.contains { $0["isReplay"] as? Bool == true && $0["uuid"] as? String == "u1" }, "codex turn/start 錯誤補 isReplay")
// 2. 插話失敗時紀錄順序：user2 要在 answer1 之後
c.outgoing(["type": "user", "uuid": "U2", "message": ["role": "user", "content": "第一則"]])
c.incoming(["method": "turn/started", "params": ["turn": ["id": "R1"]]])
c.outgoing(["type": "user", "uuid": "U3", "message": ["role": "user", "content": "插話"]])
c.steer("U3")
let steerID = lastID("turn/steer")
c.incoming(["method": "item/completed", "params": ["item": ["type": "agentMessage", "id": "A1", "text": "回答一"]]])
c.incoming(["id": steerID, "error": ["message": "no active turn"]])
c.incoming(["method": "turn/completed", "params": ["turn": ["id": "R1", "status": "completed"]]])
let lines = (try? String(contentsOf: c.transcriptURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
let iAns = lines.firstIndex { $0.contains("回答一") } ?? -1, iSteer = lines.firstIndex { $0.contains("插話") } ?? -1
print("  紀錄行：", lines.map { $0.contains("回答一") ? "答1" : $0.contains("插話") ? "插話" : $0.contains("第一則") ? "問1" : $0.contains("a.log") ? "問0" : "?" })
check(iAns >= 0 && iSteer > iAns, "codex 插話失敗紀錄排在回答後")
check(lines.filter { $0.contains("插話") }.count == 1, "codex 插話只記一次")
// 插話成功也要記一次
c.incoming(["method": "turn/started", "params": ["turn": ["id": "R2"]]])
c.outgoing(["type": "user", "uuid": "U4", "message": ["role": "user", "content": "成功插話"]])
c.steer("U4"); c.incoming(["id": lastID("turn/steer"), "result": [:]])
let l2 = (try? String(contentsOf: c.transcriptURL, encoding: .utf8)) ?? ""
check(l2.components(separatedBy: "成功插話").count - 1 == 1, "codex 插話成功記一次")
// ---- MCP 工具結果是 JSON null：以前 JSONSerialization 丟 ObjC 例外整個 App 崩潰（exit 134）；現在要照常收尾
emitted = []
c.incoming(["method": "item/started", "params": ["item": ["type": "mcpToolCall", "id": "M1", "server": "s", "tool": "t", "arguments": [String: Any]()]]])
c.incoming(["method": "item/completed", "params": ["item": ["type": "mcpToolCall", "id": "M1", "status": "completed", "result": NSNull()]]])
let nullRes = emitted.compactMap { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8) }.joined()
check(nullRes.contains("tool_result") && nullRes.contains("M1"), "codex MCP 結果為 null 不崩潰且有收尾")
// ---- Copilot 5
let cpID = UUID()
let cp = CopilotBridge(session: cpID, directory: "/tmp", model: "m")
cp.send = { sent.append($0) }; cp.emit = { emitted.append($0) }
cp.mode = "auto"; emitted = []
cp.incoming(["method": "session/update", "params": ["update": ["sessionUpdate": "tool_call", "toolCallId": "C1", "kind": "execute", "title": "Run"]]])
cp.incoming(["id": 99, "method": "session/request_permission", "params": ["toolCall": ["toolCallId": "C1", "kind": "execute", "rawInput": ["command": "ls -la /secret-dir"]], "options": [["optionId": "a", "kind": "allow_once"]]]])
cp.incoming(["method": "session/update", "params": ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "C1", "status": "completed"]]])
let last = emitted.compactMap { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8) }.filter { $0.contains("ls -la") }.joined()
check(last.contains("ls -la"), "copilot 自動放行後工具卡參數完整")
try? FileManager.default.removeItem(at: c.transcriptURL)
try? FileManager.default.removeItem(at: CopilotBridge.transcript(for: cpID))
appDefaults.removePersistentDomain(forName: "codenv-bridge-unit")
exit(failed ? 1 : 0)
