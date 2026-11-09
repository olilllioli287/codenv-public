import SwiftUI
import AppKit

// 設定的「金鑰」分頁：所有服務的 API 金鑰統一放這裡（登入鑰匙圈，KeyVault.swift）。
// 畫面永遠不顯示完整金鑰、沒有「顯示」按鈕；貼上就立刻寫進鑰匙圈並清空欄位。

struct KeyRowInfo: Identifiable {
    let id: String            // service 名稱
    let name: String
    let note: String
    let signup: String
    let service: KeyService?  // 有端點可測的才有
}

struct KeyVaultPage: View {
    @State private var rev = 0
    @State private var rows: [KeyRowInfo] = []

    var body: some View {
        Form {
            Section {
                Text(L("API 金鑰統一放在登入鑰匙圈（項目名稱 codenv-服務名、帳號 api-key），不放在設定檔、不進聊天紀錄。畫面不會顯示完整金鑰。聊天輸入框如果偵測到你貼了金鑰，會先攔下來問你要不要存到這裡。已知限制：折行金鑰不保證攔截，請用輸入框工具列的「金鑰」按鈕安全存入。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("服務")) {
                ForEach(rows) { r in KeyRow(info: r, rev: rev, onChange: { rev += 1 }) }
            }
        }
        .formStyle(.grouped)
        .onAppear { KeyGuard.wire(); reload() }
        .onChange(of: rev) { _ in reload() }
    }

    private func reload() {
        var list: [KeyRowInfo] = KeyService.known.map {
            KeyRowInfo(id: KeyVault.service($0.id), name: $0.name, note: $0.note, signup: $0.signup, service: $0)
        }
        for m in LocalModel.all {
            list.append(KeyRowInfo(id: m.secretService, name: L("本機模型：") + (m.name.isEmpty ? L("（沒有名字）") : m.name), note: m.baseURL, signup: "", service: nil))
        }
        // 其他存過的（偵測到金鑰時選了 Anthropic、GitHub…或自訂名稱）
        let shown = Set(list.map(\.id))
        for s in KeyVault.allServices() where !shown.contains(s) {
            let id = String(s.dropFirst(KeyVault.prefix.count))
            let svc = KeyService.find(id)
            list.append(KeyRowInfo(id: s, name: svc?.name ?? id, note: "", signup: svc?.signup ?? "", service: nil))
        }
        rows = list
    }
}

private struct KeyRow: View {
    let info: KeyRowInfo
    let rev: Int            // 變了就重畫（狀態重新讀鑰匙圈）；不換 id，所以列裡的錯誤說明（例如備份項目的名稱）不會被清掉
    let onChange: () -> Void
    @State private var paste = ""
    @State private var result: String?
    @State private var testing = false
    enum Pending { case delete, adopt }
    @State private var pending: Pending?
    @State private var error: String?
    @State private var adopting = false

    var body: some View {
        let st = KeyVault.status(service: info.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(info.name).fontWeight(.medium)
                Text(st.exists ? (st.last4.map { L("已設定（…") + $0 + "）" } ?? L("已設定")) : L("未設定"))
                    .font(.caption).foregroundStyle(st.exists ? Color.green : Color.secondary)
                if !info.note.isEmpty { Text(info.note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if !info.signup.isEmpty, let u = URL(string: info.signup) { Link(L("去申請"), destination: u).font(.caption) }
                if let svc = info.service, svc.modelsURL != nil {
                    Button(testing ? L("測試中…") : L("測試")) { test(svc) }.disabled(!st.exists || testing)
                }
                Button(L("刪除"), role: .destructive) { pending = .delete }.disabled(!st.exists)
            }
            HStack {
                SecureField(L("貼上新金鑰（貼上後立刻存進鑰匙圈）"), text: $paste)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .onChange(of: paste) { new in if new.count >= 16 { save() } }     // 一次貼進一長串＝貼上；逐字打的要按 Enter
                Button(L("存")) { save() }.disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if st.exists && st.last4 == nil {
                HStack(alignment: .top) {
                    Text(L("這一筆是用 security 指令建的：codenv 第一次讀會跳出鑰匙圈授權框，請按「永遠允許」；或在這裡重新貼一次金鑰。"))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(adopting ? L("處理中…") : L("重新存成 codenv 擁有")) { pending = .adopt }.disabled(adopting)
                }
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            if let r = result { Text(r).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
        .confirmationDialog(pending == .adopt ? L("把「\(info.name)」重新存成 codenv 擁有？") : L("刪除「\(info.name)」的金鑰？"),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if pending == .adopt {
                Button(L("重新存")) { adopt() }
            } else {
                Button(L("刪除"), role: .destructive) { KeyVault.delete(service: info.id); result = nil; onChange() }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(pending == .adopt ? L("codenv 會先讀出金鑰（可能跳一次授權框，按「永遠允許」）、備份、刪掉原本那筆、再自己寫回去；中途失敗時金鑰會留在備份項目裡。")
                                   : L("鑰匙圈裡的這一筆會被刪掉，沒辦法還原；要再用得重新貼上。"))
        }
    }

    /// 只在使用者自己按的時候做：讀出來（可能跳一次授權框）→ 備份 → 刪掉 → 由 codenv 寫回。任何一步失敗，金鑰都還在備份裡
    private func adopt() {
        adopting = true; error = nil
        let svc = info.id
        DispatchQueue.global(qos: .userInitiated).async {
            let e = KeyVault.adopt(service: svc)
            DispatchQueue.main.async { adopting = false; error = e; onChange() }
        }
    }

    private func save() {
        let k = paste.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        paste = ""                                       // 先清空欄位，金鑰不留在畫面狀態裡
        if let e = KeyVault.set(service: info.id, key: k) { error = e; return }
        error = nil; result = nil
        onChange()
    }

    private func test(_ svc: KeyService) {
        testing = true; result = nil
        KeyVault.test(svc) { msg in DispatchQueue.main.async { testing = false; result = msg } }
    }
}
