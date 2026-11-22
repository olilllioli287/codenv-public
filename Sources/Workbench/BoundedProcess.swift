import Foundation

/// 在背景執行緒跑一個子程序並等結果，保證「逾時一定回得來」（07-33）：
/// - 逾時器在寫 stdin 之前就排好；寫 stdin 另開執行緒（對方不讀、輸入又比管子大時，寫入會卡住，不能讓它擋住逾時）
/// - 逾時先 SIGTERM，3 秒後還活著就 SIGKILL（擋掉 SIGTERM 的程式不會讓 waitUntilExit 永遠等）
/// - 子程序結束後，孫程序可能還抓著 stdout／stderr 管線不放（EOF 永遠不來）：只再等 drainGrace 秒，不無限等
enum BoundedProcess {
    struct Result { let stdout: Data; let stderr: Data; let timedOut: Bool; let status: Int32; let reason: Process.TerminationReason }

    /// 呼叫端不能在主執行緒（會等）。run 失敗回 nil
    /// maxWait：等程序結束的最長時間（預設 timeout＋killGrace＋5 秒）。SIGKILL 殺不掉的（核心不可中斷睡眠、terminationHandler 沒來）也不讓這條執行緒永遠掛著：
    /// 超過就補殺一次、放棄等待，回 timedOut＝true、status＝-1
    static func run(_ p: Process, input: Data?, timeout: TimeInterval, drainGrace: TimeInterval = 2, killGrace: TimeInterval = 3, maxWait: TimeInterval? = nil) -> Result? {
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        let lock = NSLock()
        var out = Data(), err = Data()
        let outEOF = DispatchSemaphore(value: 0), errEOF = DispatchSemaphore(value: 0)
        func reader(_ pipe: Pipe, _ eof: DispatchSemaphore, _ store: @escaping (Data) -> Void) {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; eof.signal(); return }
                lock.lock(); store(d); lock.unlock()
            }
        }
        reader(outPipe, outEOF) { out.append($0) }
        reader(errPipe, errEOF) { err.append($0) }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // 父程序這邊的寫入端不用的要關掉，不然讀的人永遠等不到 EOF
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        var timedOut = false
        let pid = p.processIdentifier
        let killer = DispatchWorkItem {
            guard p.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { if p.isRunning { kill(pid, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        DispatchQueue.global(qos: .utility).async {
            if let input { try? inPipe.fileHandleForWriting.write(contentsOf: input) }
            try? inPipe.fileHandleForWriting.close()
        }
        let exitedInTime = exited.wait(timeout: .now() + (maxWait ?? (timeout + killGrace + 5))) == .success
        killer.cancel()
        if !exitedInTime {
            kill(pid, SIGKILL)
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); defer { lock.unlock() }
            return Result(stdout: out, stderr: err, timedOut: true, status: -1, reason: .uncaughtSignal)
        }
        _ = outEOF.wait(timeout: .now() + drainGrace)
        _ = errEOF.wait(timeout: .now() + drainGrace)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return Result(stdout: out, stderr: err, timedOut: timedOut, status: p.terminationStatus, reason: p.terminationReason)
    }
}
