import Foundation

/// 交接：另外開一個 claude 讀這段對話（--fork-session＋--no-session-persistence：原本的紀錄不動、也不多存一份分叉），
/// 寫一份給下一個接手者的交接文字。不給任何工具，只寫字。
enum Handoff {
    static let prompt = """
    請幫這段對話寫一份交接，給下一個接手的 Claude。它完全看不到這段對話，只看得到你寫的交接。用繁體中文，包含：
    1. 目標：使用者要做什麼、怎樣算做完
    2. 目前進度：已經完成什麼、驗證到什麼程度
    3. 關鍵決定和原因
    4. 重要的檔案、路徑、指令
    5. 試過沒用的方法（不要再試）
    6. 還沒做完的事、下一步
    7. 使用者的偏好和要注意的限制
    只輸出交接內容本身，不要前言，也不要使用任何工具。
    """

    /// 新聊天室的第一則訊息
    static func firstMessage(from title: String, _ text: String) -> String {
        "這是從上一個聊天室「\(title)」交接過來的。請先讀完下面的交接內容，用幾句話說你理解的目前狀態和下一步，等我確認再動手。\n\n\(text)"
    }

    /// 寫交接（背景跑，最多 5 分鐘）；回傳交接文字，或失敗的原因
    static func write(session: UUID, directory: String, model: String?, effort: String?, _ done: @escaping (Result<String, HandoffError>) -> Void) {
        var args = ["-p", "--resume", session.uuidString.lowercased(), "--fork-session", "--no-session-persistence",
                    "--tools", "", "--output-format", "json"]
        if let model { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        args.append(prompt)
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec claude \(quoted)"]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env: [String: String] = [:]
        for kv in Workspace.environment() {
            if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) }
        }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        var finished = false
        let finish = { (r: Result<String, HandoffError>) in
            DispatchQueue.main.async { if !finished { finished = true; done(r) } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch { return finish(.failure(HandoffError("開不了 claude：\(error.localizedDescription)"))) }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            timer.cancel()
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let why = p.terminationReason == .uncaughtSignal ? "超過 5 分鐘還沒寫完" : String(errText.split(separator: "\n").last ?? "沒有回應")
                return finish(.failure(HandoffError(why)))
            }
            let text = (o["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if o["is_error"] as? Bool == true || text.isEmpty { return finish(.failure(HandoffError(text.isEmpty ? "Claude 沒有寫出內容" : text))) }
            finish(.success(text))
        }
    }
}

struct HandoffError: Error {
    let message: String
    init(_ m: String) { message = m }
}
