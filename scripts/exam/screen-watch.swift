// 考卷 C140 的偵測工具：每 0.1 秒用 CGWindowListCopyWindowInfo 抓指定測試程序所有可見視窗，只讀位置、不截圖。
//   screen-watch <執行檔路徑> <秒數> <輸出檔> <ready檔>
// 先寫 ready 檔等待 open -g 啟動指定 bundle，再以 CGWindowList 監看該執行檔 PID。
// 輸出第一行 displays=<螢幕數> main=<x,y,w,h>，每個重疊另列一行，最後是 samples=… windows_seen=…
//   screen-watch --selftest                只驗重疊算法，不讀取任何真的視窗，印 ok
import AppKit
import CoreGraphics
import Darwin

func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let i = a.intersection(b)
    return !i.isNull && i.width > 1 && i.height > 1
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--selftest" {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    precondition(overlaps(CGRect(x: 100, y: 100, width: 300, height: 200), main), "在主螢幕內要算重疊")
    precondition(overlaps(CGRect(x: 1400, y: 900, width: 300, height: 200), main), "跨邊要算重疊")
    precondition(!overlaps(CGRect(x: 0, y: -1024, width: 1366, height: 1024), main), "只貼邊（在上方另一台）不算")
    precondition(!overlaps(CGRect(x: 2000, y: 0, width: 800, height: 600), main), "在右邊另一台不算")
    print("ok")
    exit(0)
}

func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

guard CommandLine.arguments.count == 5,
      let seconds = Double(CommandLine.arguments[2]), seconds > 0 else {
    FileHandle.standardError.write(Data("用法：screen-watch <執行檔路徑> <秒數> <輸出檔> <ready檔>\n".utf8)); exit(2)
}
let executable = canonicalPath(CommandLine.arguments[1])
let out = CommandLine.arguments[3]
let ready = CommandLine.arguments[4]
let appURL = URL(fileURLWithPath: executable)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard let bundleID = Bundle(path: appURL.path)?.bundleIdentifier else {
    FileHandle.standardError.write(Data("讀不到測試 App bundle identifier：\(appURL.path)\n".utf8)); exit(2)
}
try? "ready\n".write(toFile: ready, atomically: true, encoding: .utf8)

let processDeadline = Date().addingTimeInterval(20)
var targetPID: Int32?
while Date() < processDeadline {
    targetPID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first { $0.executableURL.map { canonicalPath($0.path) == executable } == true }?.processIdentifier
    if targetPID != nil { break }
    Thread.sleep(forTimeInterval: 0.02)
}

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &count)
let mainBounds = CGDisplayBounds(CGMainDisplayID())
var lines = ["displays=\(count) main=\(Int(mainBounds.minX)),\(Int(mainBounds.minY)),\(Int(mainBounds.width)),\(Int(mainBounds.height))"]
guard let pid = targetPID else {
    lines.append("process_not_found executable=\(executable)")
    try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("找不到 open -g 啟動的測試 App PID\n".utf8)); exit(3)
}
lines.append("pid=\(pid) executable=\(executable)")
var seen = Set<Int>(), reported = Set<String>(), samples = 0
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    samples += 1
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let num = w[kCGWindowNumber as String] as? Int else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        guard r.width > 1, r.height > 1, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        seen.insert(num)
        if overlaps(r, mainBounds), reported.insert("\(num)").inserted {
            lines.append(String(format: "overlap t=%.1f owner=%@ name=%@ layer=%d bounds=%d,%d,%d,%d", Date().timeIntervalSince(start),
                                (w[kCGWindowOwnerName as String] as? String) ?? "?", (w[kCGWindowName as String] as? String) ?? "",
                                (w[kCGWindowLayer as String] as? Int) ?? 0, Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)))
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
lines.append("samples=\(samples) windows_seen=\(seen.count)")
do {
    try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("無法寫入視窗偵測結果：\(error)\n".utf8)); exit(1)
}
