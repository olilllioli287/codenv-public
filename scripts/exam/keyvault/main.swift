import Foundation

// 樣本不得含私人路徑、帳號、真實金鑰（公版匯出掃描會擋；金鑰全是隨機生成的假的）

// 金鑰管理核心測試：樣式偵測、誤攔、遮罩、鑰匙圈（只用 codenv-test-<亂數>- 前綴，測完刪掉；絕不碰 codenv-nvidia 等真的項目）
let realReader = KeyVault.reader
var fails = 0
func check(_ ok: Bool, _ msg: String) { if ok { print("  通過：\(msg)") } else { print("  失敗：\(msg)"); fails += 1 } }
func rnd(_ n: Int, _ set: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") -> String { String((0..<n).map { _ in set.randomElement()! }) }

// 假金鑰（隨機生成，不是真的）
let fakes: [(String, String, String?)] = [
    ("nva" + "pi-" + rnd(64, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"), "nvapi-", "nvidia"),
    ("sk-" + "or-v1-" + rnd(64, "abcdef0123456789"), "sk-or-v1-", "openrouter"),
    ("sk-ant-" + "api03-" + rnd(80), "sk-ant-", "anthropic"),
    ("sk-" + "proj-" + rnd(60), "sk-proj-", "openai"),
    ("s" + "k-" + rnd(48), "sk-", "openai"),
    ("AI" + "za" + rnd(35), "AIza", "google"),
    ("gh" + "p_" + rnd(36), "ghp_", "github"),
    ("github" + "_pat_" + rnd(70), "github_pat_", "github"),
    ("gs" + "k_" + rnd(52), "gsk_", "groq"),
    ("h" + "f_" + rnd(34), "hf_", "huggingface"),
    ("xo" + "xb-" + rnd(12, "0123456789") + "-" + rnd(24), "xoxb-", "slack"),
    ("AK" + "IA" + rnd(16, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"), "AKIA", "aws"),
    ("sk" + "_live_" + rnd(30), "sk_live_", "stripe"),
    ("rk" + "_test_" + rnd(30), "sk_live_", "stripe"),
    ("SG" + "." + rnd(22, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") + "." + rnd(43, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"), "SG.", "sendgrid"),
    ("np" + "m_" + rnd(36), "npm_", "npm"),
    ("pypi" + "-" + rnd(70, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"), "pypi-", "pypi"),
    ("sb" + "p_" + rnd(40, "abcdef0123456789"), "sbp_", "supabase"),
]
for (k, kind, svc) in fakes {
    for ctx in ["\(k)", "我的金鑰是 \(k) 幫我設定", "export API_KEY=\"\(k)\"", "Authorization: Bearer \(k)\n下一行"] {
        let h = KeyScan.scan(ctx)
        check(h.count == 1 && h[0].text == k && h[0].kind == kind && h[0].service == svc, "攔到 \(kind) 於「\(ctx.prefix(18))…」")
    }
    let red = KeyScan.redact("前 \(k) 後")
    check(!red.contains(k) && red.contains("〔金鑰…\(k.suffix(4))〕") && red.hasPrefix("前 ") && red.hasSuffix(" 後"), "遮罩 \(kind) 只留末四碼")
}
// 高熵長字串
var highEntropy = ""
repeat { highEntropy = rnd(40) } while !KeyScan.looksRandom(highEntropy)
let h1 = KeyScan.scan("token 是 \(highEntropy) 喔")
check(h1.count == 1 && h1[0].text == highEntropy && h1[0].kind == "高熵長字串" && h1[0].service == nil, "攔到高熵長字串")


let dashes = String(repeating: "-", count: 5)      // 不在原始碼裡寫出完整的私鑰標頭（掃描工具會誤報）
// 樣式：全形、零寬字元、逐行（折行不保證攔截）、全小寫、純十六進位、AWS secret 含斜線、PEM、JWT
let nv = "nvapi-" + rnd(60, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
let fullwidth = String(nv.unicodeScalars.map { u -> Character in
    switch u.value { case 0x21...0x7E: return Character(Unicode.Scalar(u.value + 0xFEE0)!); default: return Character(u) } })
let h2 = KeyScan.scan("貼 \(fullwidth) 結束")
check(h2.count == 1 && h2[0].text == fullwidth && h2[0].key == nv, "全形字元的金鑰也攔（位置對回原文，存的是半形本體）")
check(KeyScan.redact("貼 \(fullwidth) 結束").hasPrefix("貼 〔金鑰…") , "全形金鑰遮罩")
let zw = String(nv.prefix(10)) + "\u{200B}" + String(nv.dropFirst(10).prefix(20)) + "\u{FEFF}" + String(nv.dropFirst(30))
let h3 = KeyScan.scan("貼 \(zw) 結束")
check(h3.count == 1 && h3[0].text == zw && h3[0].key == nv, "夾零寬字元的金鑰也攔（存的是乾淨本體）")
let cut = nv.index(nv.startIndex, offsetBy: 30)
let folded = String(nv[..<cut]) + "\n" + String(nv[cut...])
let foldedHits = KeyScan.scan("前文\n\(folded)\n後文")
check(!foldedHits.contains(where: { $0.text.contains("後文") }), "已知限制：折行金鑰不吞下一行一般文字")
check(KeyScan.scan("第一行有一些普通的字\n第二行也是普通的字").isEmpty, "一般兩行文字不因為合併誤攔")
var lower = ""
repeat { lower = rnd(40, "abcdefghijklmnopqrstuvwxyz0123456789") } while !KeyScan.looksRandom(lower)
check(KeyScan.scan("token \(lower)").count == 1, "全小寫英數 40 字也攔")
let hx32 = rnd(32, "0123456789abcdef"), hx40 = rnd(40, "0123456789abcdef"), hx64 = rnd(64, "0123456789abcdef")
for (n, hx) in [("32", hx32), ("40", hx40), ("64", hx64)] {
    check(KeyScan.scan("api key: \(hx)").count == 1, "\(n) 位十六進位＋前後文有 api key：攔")
    check(KeyScan.scan("SECRET=\(hx)").count == 1, "\(n) 位十六進位＋SECRET=：攔")
    check(KeyScan.scan("commit \(hx)").isEmpty, "\(n) 位十六進位＋commit：放行")
    check(KeyScan.scan("這個數字 \(hx) 沒有別的說明").isEmpty, "\(n) 位十六進位沒有前後文：放行")
}
check(KeyScan.scan("api key\n\(hx32)\n").count == 1, "十六進位獨占一行、上一行寫 api key：攔")
check(KeyScan.scan("550e8400-e29b-41d4-a716-446655440000 is my api key").isEmpty, "UUID 放行（即使旁邊有 api key）")
let aws = rnd(13) + "/" + rnd(7) + "/" + rnd(18)      // 40 字、含 2 個斜線（隨機生成，不是任何真的金鑰）
check(KeyScan.scan("aws_secret_access_key = \(aws)").count == 1, "AWS secret（含 2 個斜線）攔")
let pem = dashes + "BEGIN OPENSSH " + "PRIVATE KEY" + dashes + "\n" + rnd(64) + "\n" + rnd(64) + "\n" + dashes + "END OPENSSH " + "PRIVATE KEY" + dashes
let hp = KeyScan.scan("我的 key\n\(pem)\n結束")
check(hp.count == 1 && hp[0].kind == "私鑰" && hp[0].text == pem, "PEM 私鑰整塊攔")
check(KeyScan.scan(dashes + "BEGIN RSA " + "PRIVATE KEY" + dashes + "\nabc").count == 1, "PEM 沒有結尾也攔")
let jwt = "eyJ" + rnd(30, "abcdefghijklmnopqrstuvwxyz0123456789") + "." + rnd(40, "abcdefghijklmnopqrstuvwxyz0123456789") + "." + rnd(30, "abcdefghijklmnopqrstuvwxyz0123456789")
let hj = KeyScan.scan("jwt: \(jwt)")
check(hj.count == 1 && hj[0].low && !hj[0].strong, "JWT 攔、歸低信心")
check(KeyScan.redact("jwt: \(jwt)", strongOnly: true) == "jwt: \(jwt)", "strongOnly 不動低信心的 JWT")

// 折行案例改為已知限制；單行前綴、PEM、JWT 與誤攔防護照常考。
let a1 = "nvapi-" + rnd(50), a2 = "nvapi-" + rnd(50)
let two = KeyScan.scan("\(a1)\n\(a2)\n")
check(two.count == 2 && two[0].key == a1 && two[1].key == a2, "逐行攔截相鄰兩把完整金鑰")
let prose = KeyScan.scan("\(a1)\n下一行是一般的句子 not a key at all\n")
check(prose.count == 1 && prose[0].key == a1, "金鑰後接一般文字：只攔有效命中")
let thanksHits = KeyScan.scan("nvapi-1234567890abcdefghijklmnopqrstuvwxyz1234567890\nthanks")
check(thanksHits.count == 1 && thanksHits[0].key.hasPrefix("nvapi-"), "完整 nvapi 後的 thanks 不併入")
let fileHits = KeyScan.scan("nvapi-1234567890abcdefghijklmnopqrstuvwxyz1234567890\nmain.swift")
check(fileHits.count == 1 && fileHits[0].key.hasPrefix("nvapi-"), "完整 nvapi 後的檔名保留")
let awsSecret = ["wJalrXUtn", "FEMI/K7MDENG", "/bPxRfiCYEXAMPLEKEY"].joined()
let awsSecretHits = KeyScan.scan("nvapi-1234567890abcdefghijklmnopqrstuvwxyz1234567890\n" + awsSecret)
check(awsSecretHits.count == 2, "相鄰行各自檢查，不合併")
let foldedAKIAHits = KeyScan.scan("AKIA123456\n7890ABCDEF\nok")
check(!foldedAKIAHits.contains(where: { $0.text.contains("ok") }), "已知限制：折行案例不吞下一行一般文字")
let quotedFold = KeyScan.scan("API_KEY=\"nvapi-1234567890abcde\nfghijklmnopqrstuvwxyz12345\"")
check(!quotedFold.contains(where: { $0.text.contains("\nfghijklmnopqrstuvwxyz12345") }), "引號內折行不吞進下一行")
let halfFold = KeyScan.scan("API_KEY=\"nvapi-1234567890abcdefghijklmnopqrst\nuvwxyz1234567890abcdefghijklmn\"")
check(halfFold.count == 1 && halfFold[0].key == "nvapi-1234567890abcdefghijklmnopqrst", "折行後半段不接入金鑰")
let fullwidthEndHits = KeyScan.scan("nvapi-1234567890abcdefghijklmnopqrst\u{3000}\nuvwxyz1234567890abcdefghijklmn")
check(fullwidthEndHits.count <= 1, "已知限制：全形空白折行不保證攔截")
let pemBody = "MIIEpAIBAAKCAQEA0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL"
let unclosedPEM = dashes + "BEGIN RSA PRIVATE KEY" + dashes + "\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,0123456789ABCDEF\n\n  " + pemBody + "   \naB3dE5fG=="
let pemStrong = KeyScan.redact(unclosedPEM, strongOnly: true)
check(!pemStrong.contains(pemBody) && !pemStrong.contains("aB3dE5fG=="), "K01 Argon 4：未閉合 PEM 的標頭、縮排、尾空白及短末行皆遮罩")
let sl = KeyScan.redact("-----BEGIN RSA PRIVATE KEY-----\n" + rnd(40) + "\n\n之後一般文字 還在")
check(sl.hasSuffix("之後一般文字 還在") && !sl.contains("BEGIN RSA"), "沒結尾的私鑰標頭：只遮到空行，後面一般文字還在")
// 低信心在前、後面還有真金鑰：每個命中都要各自處理（原生考卷 C50 另測）
check(KeyScan.scan("\(a1) \(jwt)").count == 2, "金鑰＋JWT 並存：兩個命中")
// 拒絕後不會永遠秒失敗；-25308 單獨一類
KeyVault.reader = { _ in (-25308, nil) }
check(KeyVault.readBounded(KeyVault.service("again"), wait: 1) == .denied(-25308), "不允許互動：回 denied(-25308)")
KeyVault.reader = { _ in (0, "later-ok") }
check(KeyVault.readBounded(KeyVault.service("again"), wait: 1) == .value("later-ok"), "拒絕過一次之後，下一次重新問就成功（不會永遠秒失敗）")
KeyVault.reader = realReader
KeyVault.forget(KeyVault.service("again"))
// 「這段不是金鑰」白名單：只記雜湊
KeyScan.allowHashes = [KeyScan.hash(lower)]
check(KeyScan.scan("token \(lower)").isEmpty, "加入白名單的那段不再攔")
KeyScan.allowHashes = []
check(KeyScan.hash("abc").count == 64 && !KeyScan.hash("abc").contains("abc"), "白名單只存雜湊")

// 不能誤攔
let hex40 = "3f786850e387550fdab836ed7e6dc881de23001b"
let normals = [
    "commit \(hex40) 修好了", "sha256 " + String(repeating: "ab12", count: 16),
    "UUID 550e8400-e29b-41d4-a716-446655440000 就是它",
    "/home/dev/app/src/components/MainWindowController.swift",
    "~/Library/Application Support/codenv/transcripts/金鑰管理.md",
    "https://github.com/olilllioli287/codenv/blob/main/Sources/Workbench/KeyVault.swift",
    "ThisIsAVeryLongCamelCaseIdentifierNameForAFunction", "some_very_long_snake_case_identifier_name_here_for_testing",
    "請幫我把 ChatInputBar.swift 的 send() 加上攔截，然後跑 swift build",
    "sk-short", "nvapi-", "AIza123", "今天天氣很好，我想吃牛肉麵。",
    "git rev-parse HEAD → \(hex40)", "data:image/png;base64," + rnd(120),
    "integrity \"sha512-" + rnd(86, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/") + "==\"",
    "integrity sha384-" + rnd(64, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/"),
    "/home/dev/app/src/components/deep/nested/MainWindowController2024.swift",
    "/home/dev/a/b/Some-Very-Long-File-Name-Version-2-Final-Draft-Of-Report.docx",
    "src/components/ui/buttons/PrimaryButtonWithLongName2024Version3.swift",
    "~/Library/Application Support/Some Long Application Name/transcripts/2026-11-08T10-20-30-session-0001.md",
    "路徑 /home/dev/My Documents/Some Long Folder Name/another-long-file-name-2026-final-v2-revised.txt 在這裡",
    "c0ffee1234 修好登入 bug（git log --oneline）", "some_very_long_snake_case_identifier_name_here_for_testing",
    "commit \(hx32) api 的修改", "sha256 \(hx64) token 檔案",
]
for n in normals { check(KeyScan.scan(n).isEmpty, "不誤攔「\(n.prefix(30))…」") }
check(KeyScan.redact("正常文字 \(hex40)") == "正常文字 \(hex40)", "遮罩不動正常文字")

// 「金鑰」面板流程：假儲存，兩行折斷貼入後寫成一串，輸入只得到佔位字。
let pasted = "nvapi-" + rnd(30) + "\n" + rnd(34)
var fakeStored = ""
let pasteResult = KeyVaultPaste.save(pasted, service: "nvidia") { _, key in fakeStored = key; return nil }
check(fakeStored == pasted.replacingOccurrences(of: "\n", with: ""), "假儲存：貼兩行折斷金鑰後存成一串")
check(pasteResult.placeholder == "〔金鑰：NVIDIA，已存〕" && pasteResult.placeholder?.contains(fakeStored) == false, "假儲存：輸入框只出現佔位字")

// 鑰匙圈（測試專用前綴）
let pre = "codenv-test-" + rnd(10, "abcdef0123456789") + "-"
KeyVault.prefix = pre
func cleanup() { for s in KeyVault.allServices() { KeyVault.delete(service: s) } }
let svc = KeyVault.service("nvidia")
check(svc.hasPrefix("codenv-test-"), "測試 service 帶 codenv-test- 前綴")
check(KeyVault.status(service: svc).exists == false, "一開始沒有")
let secret = "nvapi-" + rnd(40)
check(KeyVault.set(service: svc, key: "  " + secret + "\n") == nil, "寫入（去掉前後空白）")
check(KeyVault.read(service: svc) == secret, "讀回一致")
let st = KeyVault.status(service: svc)
check(st.exists && st.last4 == String(secret.suffix(4)), "狀態只看屬性：存在＋末四碼")
let secret2 = "nvapi-" + rnd(40)
check(KeyVault.set(service: svc, key: secret2) == nil && KeyVault.read(service: svc) == secret2 && KeyVault.status(service: svc).last4 == String(secret2.suffix(4)), "覆蓋更新")
let raceSvc = KeyVault.service("race")
func raceMutation(_ mutate: () -> Void, _ label: String) {
    let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    KeyVault.reader = { _ in began.signal(); _ = release.wait(timeout: .now() + 3); return (0, "stale") }
    KeyVault.prefetch(raceSvc)
    _ = began.wait(timeout: .now() + 2)
    mutate()
    release.signal()
    Thread.sleep(forTimeInterval: 0.1)
    check(KeyVault.cached(raceSvc) == nil, "Argon 6：\(label)使並行舊讀取失效，不快取舊值")
}
raceMutation({ _ = KeyVault.set(service: raceSvc, key: "nvapi-race-set-value-12345678901234567890") }, "set")
raceMutation({ _ = KeyVault.delete(service: raceSvc) }, "delete")
KeyVault.reader = realReader
KeyVault.forget(raceSvc)
_ = KeyVault.delete(service: raceSvc)
check(KeyVault.set(service: KeyVault.customService(named: "My Cool 服務!"), key: "abc12345") == nil, "自訂名稱可存")
check(KeyVault.customService(named: "My Cool 服務!") == pre + "other-my-cool", "自訂名稱轉成 service：\(KeyVault.customService(named: "My Cool 服務!"))")
check(Set(KeyVault.allServices()) == Set([svc, pre + "other-my-cool"]), "列表只含這次測試的項目")
check(KeyVault.set(service: svc, key: "   ") != nil, "空金鑰拒絕")
check(KeyVault.delete(service: svc) && KeyVault.status(service: svc).exists == false && KeyVault.read(service: svc) == nil, "刪除")
check(KeyVault.delete(service: svc), "重複刪除不報錯")

// 測試按鈕：假金鑰打本機假伺服器（失敗路徑＋成功路徑），不連外
let sema = DispatchSemaphore(value: 0)
var got = ""
KeyVault.test(KeyService.known[0], key: "nvapi-" + rnd(30), urlOverride: "http://127.0.0.1:9/none") { got = $0; sema.signal() }
_ = sema.wait(timeout: .now() + 20)
check(got.hasPrefix("連不上"), "測試：連不上時說連不上（\(got)）")
KeyVault.test(KeyService.known[0], key: nil, urlOverride: "http://127.0.0.1:9/none") { got = $0; sema.signal() }
_ = sema.wait(timeout: .now() + 5)
check(got == "還沒有設定金鑰", "測試：沒設定金鑰時不連線")

// 鑰匙圈讀取：不卡住、拒絕要明確（用假的 reader 模擬，不會真的跳授權框）
KeyVault.reader = { _ in (-128, nil) }
check(KeyVault.readBounded(KeyVault.service("deny"), wait: 1) == .denied(-128), "使用者按拒絕：回 denied（不是空字串）")
KeyVault.forget(KeyVault.service("deny"))
KeyVault.reader = { _ in Thread.sleep(forTimeInterval: 3); return (0, "slowkey") }
let t0 = Date()
let slow = KeyVault.readBounded(KeyVault.service("slow"), wait: 0.5)
check(slow == .pending && Date().timeIntervalSince(t0) < 1.5, "授權框一直開著：最多等 0.5 秒就回 pending，不卡住")
Thread.sleep(forTimeInterval: 3.3)
check(KeyVault.cached(KeyVault.service("slow")) == .value("slowkey"), "使用者之後按了允許：背景讀完填進快取")
KeyVault.reader = { _ in (errSecItemNotFound, nil) }
check(KeyVault.readBounded(KeyVault.service("none"), wait: 1) == .missing, "沒有這筆：回 missing")
KeyVault.reader = realReader
// 讀取中途刪掉：舊的讀取不能把已刪的金鑰放回快取
let ghost = KeyVault.service("ghost")
KeyVault.reader = { _ in Thread.sleep(forTimeInterval: 1); return (0, "ghostkey") }
_ = KeyVault.readBounded(ghost, wait: 0.2)
KeyVault.delete(service: ghost)
Thread.sleep(forTimeInterval: 1.3)
check(KeyVault.cached(ghost) == nil, "刪除時還在讀的舊讀取，讀完不會把金鑰放回快取")
KeyVault.reader = realReader
// 沒結尾的私鑰標頭放進 JSON 紀錄：遮完 JSON 仍然合法
let pemObj: [String: Any] = ["message": ["content": "貼了 " + dashes + "BEGIN RSA " + "PRIVATE KEY" + dashes + "\n" + rnd(40)], "after": "後面的欄位"]
let pj = Transcripts.redactedJSON(pemObj)
check(pj != nil && (try? JSONSerialization.jsonObject(with: pj!)) != nil && String(data: pj!, encoding: .utf8)!.contains("後面的欄位"), "沒結尾的私鑰標頭：遮完的 JSON 仍合法、後面欄位還在")

// 「重新存成 codenv 擁有」：讀出來→備份→刪除→寫回→刪備份
let adoptSvc = KeyVault.service("adoptme")
let adoptKey = "nvapi-" + rnd(40)
KeyVault.reader = { s in s == adoptSvc ? (0, adoptKey) : (errSecItemNotFound, nil) }
check(KeyVault.adopt(service: adoptSvc) == nil, "重新存成 codenv 擁有：成功")
KeyVault.reader = realReader
check(KeyVault.read(service: adoptSvc) == adoptKey && KeyVault.isCodenvOwned(service: adoptSvc), "  金鑰一致且有末四碼（codenv 擁有）")
check(KeyVault.allServices().filter { $0.contains("-backup-") }.isEmpty, "  備份項目已刪除")
KeyVault.reader = { _ in (-128, nil) }
check(KeyVault.adopt(service: adoptSvc) != nil && KeyVault.read(service: adoptSvc) == adoptKey, "讀不到（拒絕）時不動原項目")
KeyVault.reader = realReader

cleanup()
print(fails == 0 ? "全部通過" : "失敗 \(fails) 項")
exit(fails == 0 ? 0 : 1)
