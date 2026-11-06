import Foundation
var bad = false
let a = AgyBridge(session: UUID(), model: "m")
a.cancelled = ["舊問題"]
let r1 = a.outgoing(["type": "user", "uuid": "X", "message": ["role": "user", "content": "/compact"]])
let c1 = (r1?["message"] as? [String: Any])?["content"] as? String ?? ""
print(c1 == "/compact" ? "PASS" : "FAIL", "agy /compact 不加附註", c1.prefix(20)); if c1 != "/compact" { bad = true }
let r2 = a.outgoing(["type": "user", "uuid": "Y", "message": ["role": "user", "content": "下一題"]])
let c2 = (r2?["message"] as? [String: Any])?["content"] as? String ?? ""
print(c2.contains("舊問題") ? "PASS" : "FAIL", "agy 附註留到下一則"); if !c2.contains("舊問題") { bad = true }
exit(bad ? 1 : 0)
