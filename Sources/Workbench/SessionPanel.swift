import SwiftUI
import AppKit

// 點上面的「Session」（或 Ctrl+A s／w）跳出來的浮動面板，跟模型選單同一個樣子：
//   Session 一行、底下列它的 Window，目前的打勾；下面是新 Session、改名、關掉。↑ ↓ 選、Enter 確定、Esc 關。

struct SessionPanelRow: Identifiable, Equatable {
    let id: String
    let title: String
    let isSession: Bool
    let checked: Bool
    let session: UUID
    let window: UUID?
}

final class SessionPanelModel: ObservableObject {
    @Published var rows: [SessionPanelRow] = []
    @Published var canClose = false
    @Published var keyIndex: Int?          // 用鍵盤選到第幾行（nil＝還沒按方向鍵）
    var onPick: ((SessionPanelRow) -> Void)?
    var onNew: (() -> Void)?
    var onRename: (() -> Void)?
    var onCloseSession: (() -> Void)?
}

struct SessionPanel: View {
    @ObservedObject var m: SessionPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Session 和 Window")).font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(m.rows.enumerated()), id: \.element.id) { i, row in
                        if row.isSession && i > 0 { Divider().opacity(0.4).padding(.vertical, 4).padding(.horizontal, 12) }
                        Button(action: { m.onPick?(row) }) {
                            HStack {
                                Text(row.title)
                                    .font(.system(size: row.isSession ? 15 : 14, weight: row.isSession ? .semibold : .regular))
                                    .foregroundStyle(row.isSession ? Color.accentColor : Color.primary)
                                    .lineLimit(1)
                                Spacer()
                                if row.checked { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                            }
                            .padding(.leading, row.isSession ? 18 : 34).padding(.trailing, 18).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverPlain(marked: m.keyIndex == i))
                    }
                }
            }
            .frame(height: listHeight)
            Divider().opacity(0.4).padding(.vertical, 4).padding(.horizontal, 12)
            action(L("新 Session…"), key: "", m.onNew)
            action(L("幫這個 Session 改名…"), key: "Ctrl+A $", m.onRename)
            if m.canClose { action(L("關掉這個 Session（對話留在側欄）"), key: "", m.onCloseSession) }
            Spacer().frame(height: 8)
        }
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private func action(_ title: String, key: String, _ f: (() -> Void)?) -> some View {
        Button(action: { f?() }) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
                if !key.isEmpty { Text(key).font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 18).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverPlain())
    }

    /// 清單照行數撐開（每列約 32 點、Session 之間的分隔線約 9 點），最多 420，超過可以捲
    private var listHeight: CGFloat {
        let sessions = m.rows.filter(\.isSession).count
        return min(420, CGFloat(m.rows.count) * 32 + CGFloat(max(0, sessions - 1)) * 9)
    }
}
