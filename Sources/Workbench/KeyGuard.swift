import AppKit

// 聊天輸入框送出前的金鑰攔截（所有引擎共用：輸入框是唯一入口，Claude、Codex、Copilot、agy、OpenCode、本機模型都經過這裡）。
// 命中就不送出，跳卡片：存到金鑰管理（輸入框裡那段換成〔金鑰：NVIDIA，已存〕）／取消／仍要送出（再確認一次）。
// 偵測樣式在 KeyVault.swift 的 KeyScan。

enum KeyGuardDecision {
    case save(service: String, label: String)    // service＝鑰匙圈 service 全名；label＝輸入框裡顯示的名字
    case sendAnyway
    case notAKey                                 // 「這段不是金鑰，以後別再攔」：記雜湊（不記原文）後照常送
    case cancel
}

enum KeyGuard {
    /// 測試用：直接給決定，不跳視窗（--keyguard-test）
    static var testDecision: ((KeyHit) -> KeyGuardDecision)?
    static var testConfirm: (() -> Bool)?
    static var testFileDecision: (() -> Bool)?
    static var testBigFileDecision: (() -> Bool)?

    private static let allowKey = "keyAllowHashes"
    private static var wired = false
    /// 把「這段不是金鑰」的雜湊清單接上設定檔（只記雜湊）。第一次用到時接
    static func wire() {
        guard !wired else { return }
        wired = true
        KeyScan.allowHashes = Set((appDefaults.array(forKey: allowKey) as? [String]) ?? [])
    }
    static func allow(_ text: String) {
        wire()
        KeyScan.allowHashes.insert(KeyScan.hash(text))
        appDefaults.set(Array(KeyScan.allowHashes), forKey: allowKey)
    }
    static func shortHint(_ hit: KeyHit) -> String { "\(hit.kind)…" + String(hit.key.suffix(4)) }

    /// 卡片：這一段看起來像金鑰
    static func ask(_ hit: KeyHit) -> KeyGuardDecision {
        if let t = testDecision { return t(hit) }
        let items: [KeyService] = KeyService.known + KeyService.extra.filter { $0.id != "other" }
        let a = NSAlert()
        a.messageText = L("這看起來像 API 金鑰")
        let info = L("送出會留在聊天紀錄，並傳給模型。要改存到金鑰管理嗎？\n偵測到：") + shortHint(hit)
        a.informativeText = info
        a.addButton(withTitle: L("存到金鑰管理"))
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("仍要送出…"))
        a.addButton(withTitle: L("這段不是金鑰，以後別再攔"))
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 28, width: 260, height: 26), pullsDown: false)
        pop.addItems(withTitles: items.map(\.name) + [L("其他（自己取名）")])
        let guess = items.firstIndex { $0.id == hit.service } ?? items.count
        pop.selectItem(at: guess)
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = L("取個名字，例如 my-service")
        name.isHidden = guess != items.count
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(pop); box.addSubview(name)
        final class Toggler: NSObject {
            let pop: NSPopUpButton, field: NSTextField, last: Int
            init(_ p: NSPopUpButton, _ f: NSTextField, _ l: Int) { pop = p; field = f; last = l }
            @objc func changed() { field.isHidden = pop.indexOfSelectedItem != last }
        }
        let tg = Toggler(pop, name, items.count)
        pop.target = tg; pop.action = #selector(Toggler.changed)
        a.accessoryView = box
        while true {
            let r = withExtendedLifetime(tg) { a.runModal() }
            switch r {
            case .alertFirstButtonReturn:
                let i = pop.indexOfSelectedItem
                let service: String, label: String
                if i < items.count {
                    service = KeyVault.service(items[i].id); label = items[i].name
                } else {
                    let n = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if n.isEmpty { NSSound.beep(); name.isHidden = false; continue }     // 沒取名：卡片留著
                    service = KeyVault.customService(named: n); label = n
                }
                // 這個名字已經有金鑰了：問過才覆蓋（不同的名字可能轉成同一個項目名稱）
                if KeyVault.status(service: service).exists {
                    let c = NSAlert()
                    c.messageText = L("「\(label)」已經有一把金鑰了，要換成這一把嗎？")
                    c.informativeText = L("舊的會被覆蓋，沒辦法還原。")
                    c.addButton(withTitle: L("取消")); c.addButton(withTitle: L("覆蓋"))
                    if c.runModal() != .alertSecondButtonReturn { continue }
                }
                return .save(service: service, label: label)
            case .alertThirdButtonReturn:
                if hit.low { return .sendAnyway }          // 低信心（JWT）：不用再確認第二次
                return confirmSend() ? .sendAnyway : .cancel
            case NSApplication.ModalResponse(rawValue: 1003):
                return .notAKey
            default:
                return .cancel
            }
        }
    }

    static func confirmSend() -> Bool {
        if let t = testConfirm { return t() }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = L("真的要把這串金鑰送出嗎？")
        a.informativeText = L("它會寫進聊天紀錄（~/.claude/projects 底下的檔案，之後沒辦法從那裡刪乾淨），也會傳給模型供應商。送出後只能去服務商那邊作廢重產。")
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("仍要送出"))
        return a.runModal() == .alertSecondButtonReturn
    }

    /// 附進來的檔案裡面有金鑰：不能替換（檔案不是輸入框的字），只能取消或仍要送出
    static func askFiles(_ names: [String], truncated: Bool = false) -> Bool {      // true＝仍要送出
        if let t = testFileDecision { return t() }
        let a = NSAlert()
        a.messageText = L("附的檔案裡有像 API 金鑰的內容")
        a.informativeText = L("檔案：") + names.joined(separator: "、") + (truncated ? L("\n（有的檔案超過 8 MB，只掃了前 8 MB。）") : "") + L("\n模型讀了檔案，金鑰就會留在聊天紀錄並傳給模型。建議先把金鑰從檔案拿掉，改存到設定的「金鑰」分頁。")
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("仍要送出…"))
        guard a.runModal() == .alertSecondButtonReturn else { return false }
        return confirmSend()
    }

    /// 附的檔案超過 8 MB：只檢查了前 8 MB，後面沒檢查。true＝仍要送出
    static func askBigFiles(_ names: [String]) -> Bool {
        if let t = testBigFileDecision { return t() }
        let a = NSAlert()
        a.messageText = L("這個檔案只檢查了前 8 MB")
        a.informativeText = L("檔案：") + names.joined(separator: "、") + L("\n超過 8 MB 的部分沒有檢查有沒有 API 金鑰。要照樣送出嗎？")
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("照樣送出"))
        return a.runModal() == .alertSecondButtonReturn
    }

    /// 檔案裡有沒有像金鑰的內容（分段讀、最多看前 8 MB；二進位檔看不出內容）
    static func fileIsOverScanLimit(_ url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 8_000_000 }
    static func fileHasKey(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey]), v.isRegularFile == true,
              let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        // 最多看前 8 MB（分段讀，段與段重疊 256 字元，免得金鑰剛好被切斷）
        var carry = "", total = 0
        while total < 8_000_000, let d = try? h.read(upToCount: 1_000_000), !d.isEmpty {
            total += d.count
            guard let chunk = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self) as String? else { return false }
            let text = carry + chunk
            if !KeyScan.scan(text).isEmpty { return true }
            carry = String(text.suffix(256))
        }
        return false
    }
}
