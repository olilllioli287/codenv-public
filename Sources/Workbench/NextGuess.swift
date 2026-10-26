import Foundation
import FoundationModels

// 輸入框的灰字建議（猜使用者下一句）：Claude Code 自己會猜（--prompt-suggestions），
// 其他聊天室（Gemini、ChatGPT、Copilot、本機模型）沒有這個功能，所以每輪結束後另外找模型猜一句：
// Gemini 3.8 Flash 的聊天室用 Flash 自己（low，經 agy，實測約 5 秒，花 Flash 額度）；其他的用 Apple 內建模型（0.3～1.3 秒，不花額度）。
// 使用者 10/24 指定這樣分。猜的模型不能用就不猜，不互相退回。設定頁的「建議下一句」關掉也不猜。

enum NextGuess {
    /// 每個聊天室一個：記下這輪使用者打的字和助手說的話，這輪結束就去猜
    final class Tracker {
        private var user = ""
        private var texts: [String] = []
        private var cancel: (() -> Void)?        // 還沒猜完的那個：新的一輪開始就停掉
        private var round = 0                     // 每輪加一：舊的猜測晚到就丟掉

        /// 使用者送出一則（新的一輪開始）：之前還沒猜完的作廢
        func sent(_ text: String) {
            user = text
            texts = []
            round += 1
            cancel?()
            cancel = nil
        }

        /// 畫面收到的每個事件（Claude Code 格式）都丟進來；這輪結束（result）而且有回覆文字時，猜好呼叫 done。
        /// flash：這是 Gemini 3.8 Flash 的聊天室，用 Flash 自己猜
        func saw(_ obj: [String: Any], flash: Bool, done: @escaping (String) -> Void) {
            switch obj["type"] as? String {
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for b in content where b["type"] as? String == "text" {
                    if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { texts.append(t) }
                }
            case "result":
                guard obj["is_error"] as? Bool != true, !texts.isEmpty else { texts = []; return }
                let reply = texts.joined(separator: "\n\n")
                texts = []
                round += 1
                let r = round
                cancel?()
                let got: (String) -> Void = { [weak self] s in
                    guard let self, self.round == r else { return }
                    self.cancel = nil
                    done(s)
                }
                cancel = flash ? NextGuess.runFlash(user: user, assistant: reply, done: got) : NextGuess.run(user: user, assistant: reply, done: got)
            default:
                break
            }
        }
    }

    static func prompt(user: String, assistant: String) -> String {
        """
        你是輸入法的預測功能。下面是使用者和 AI 助手最近一輪的對話。請猜使用者下一句最可能打的話：繁體中文、使用者自己的口吻、20 字以內（英文單字一個算一字）。只輸出那句話本身，不要引號、不要解釋、不要用任何工具。真的猜不到就只輸出「（無）」。

        使用者：\(user.suffix(1000))
        助手：\(assistant.suffix(2000))
        """
    }

    /// 背景請 Apple 模型猜一句；猜不到（或模型不能用、設定關掉）就不呼叫 done。done 在主執行緒。回傳停掉它的方法
    static func run(user: String, assistant: String, done: @escaping (String) -> Void) -> (() -> Void)? {
        guard Prefs.shared.promptSuggestions, AppleBridge.available else { return nil }
        let prompt = prompt(user: user, assistant: assistant)
        guard #available(macOS 26.4, *) else { return nil }
        let t = Task {
            // 上下文只有約 8K：上面已經截短；被拒答、太長、出錯都當沒猜到
            guard let r = try? await LanguageModelSession().respond(to: prompt), !Task.isCancelled else { return }
            let s = clean(r.content)
            guard !s.isEmpty, !s.hasPrefix("無法") else { return }
            await MainActor.run { done(s) }
        }
        return { t.cancel() }
    }

    static let flashModel = "gemini-3.8-flash-low"

    /// 背景跑 agy 的 Flash（low）猜一句；agy 沒裝、設定關掉、逾時都不呼叫 done。done 在主執行緒。回傳停掉它的方法
    static func runFlash(user: String, assistant: String, done: @escaping (String) -> Void) -> (() -> Void)? {
        guard Prefs.shared.promptSuggestions, AgyBridge.enabled, FileManager.default.isExecutableFile(atPath: AgyBridge.executable) else { return nil }
        // 在暫存資料夾跑：不讀任何專案檔
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-next-guess")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: AgyBridge.executable)
        let log = AgyNet.newLogFile()
        p.arguments = ["--model", flashModel, "--print-timeout", "30s", "--log-file", log.path, "-p=" + prompt(user: user, assistant: assistant)]
        p.currentDirectoryURL = dir
        let out = Pipe()
        // stderr 寫檔不接 Pipe：量大時管線塞滿會讓 agy 卡住
        let errURL = dir.appendingPathComponent("err-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        p.standardOutput = out
        let errFile = try? FileHandle(forWritingTo: errURL)
        p.standardError = errFile ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let d = out.fileHandleForReading.readDataToEndOfFile()
            let e = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: errURL)
            AgyNet.check(log: log)
            // 逾時 agy 仍回 0，輸出只有半句：丟掉
            let s = e.contains("print timeout") ? "" : clean(String(data: d, encoding: .utf8) ?? "")
            DispatchQueue.main.async { if proc.terminationStatus == 0, !s.isEmpty { done(s) } }
        }
        // 先在背景確認連得到 Google 才開 agy（斷網時 agy 會開瀏覽器登入頁）；連不到就安靜地不猜
        let lock = NSLock()
        var stopped = false
        DispatchQueue.global(qos: .utility).async {
            defer { try? errFile?.close() }  // agy 已經拿到自己那份，這邊的關掉
            let online = AgyNet.canCall()
            lock.lock(); defer { lock.unlock() }
            guard online, !stopped, (try? p.run()) != nil else { try? FileManager.default.removeItem(at: errURL); return }
        }
        return { lock.lock(); stopped = true; lock.unlock(); if p.isRunning { p.terminate() } }
    }

    /// 只留第一行、拿掉引號；「（無）」或太長（多半是在解釋）就當沒猜到。長度用 length 算：英文單字一個算一字
    static func clean(_ raw: String) -> String {
        var s = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for (a, b) in [("「", "」"), ("\"", "\""), ("“", "”"), ("『", "』")] where s.hasPrefix(a) && s.hasSuffix(b) && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if s.contains("（無）") || s.contains("(無)") || length(s) > 40 { return "" }
        return s
    }

    /// 中文一個字算一字，連在一起的英文字母、數字（含 _ . - / 這類寫在名稱裡的符號）整串算一字，空白不算
    static func length(_ s: String) -> Int {
        var n = 0, inWord = false
        for ch in s {
            if ch.isASCII, ch.isLetter || ch.isNumber || "_.-/".contains(ch) {
                if !inWord { n += 1; inWord = true }
            } else {
                inWord = false
                if !ch.isWhitespace { n += 1 }
            }
        }
        return n
    }
}
