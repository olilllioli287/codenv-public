import SwiftUI
import AppKit

/// agy 預設開啟的一次性提醒：只告知、不擋功能。浮在主視窗上方的小卡片（nonactivating，顯示時不搶焦點、不打斷輸入），
/// 按「知道了」或「前往設定」都記成已看過，之後不再出現。偵測到本機裝了 agy、而且還沒看過才會出現（Prefs.checkAgyNotice）。
struct AgyNoticeCard: View {
    @Environment(\.colorScheme) private var scheme
    var onKnow: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("agy 功能預設開著")).font(.system(size: 14, weight: .semibold))
            Text(L("codenv 偵測到這台電腦裝了 Google 的 agy，預設會用它來做這些事："))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("・Gemini 聊天室，以及用 codenv-todo 開的 agy 聊天室"))
                Text(L("・輸入框的灰字下一句建議"))
                Text(L("・用量查詢（輸入框下方 agy 的額度）"))
                Text(L("・看板上讓 Claude 自動派工作給 agy"))
            }.font(.system(size: 12))
            Text(L("Google 的個人方案不支援把 agy 包進第三方 App；使用風險由你自己承擔（FAQ：https://antigravity.google/docs/faq/）。"))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(L("想關掉：設定 → 對話 → agy。這則提醒只會出現一次。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("前往設定"), action: onSettings)
                Button(L("知道了"), action: onKnow).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15)))
        .padding(10)
    }
}

final class AgyNoticePanel: NSPanel {
    static var current: AgyNoticePanel?
    override var canBecomeKey: Bool { true }

    static func show(onKnow: @escaping () -> Void, onSettings: @escaping () -> Void) {
        guard current == nil else { return }
        let host = NSHostingView(rootView: AgyNoticeCard(onKnow: { dismiss(); onKnow() }, onSettings: { dismiss(); onSettings() }))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let p = AgyNoticePanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // 主視窗上方正中間；找不到主視窗就放主螢幕上方
        let anchor = NSApp.windows.first(where: { $0.windowController is MainWindowController && $0.isVisible })?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        p.setFrameTopLeftPoint(NSPoint(x: anchor.midX - host.frame.width / 2, y: anchor.maxY - 40))
        current = p
        p.orderFront(nil)          // 不 makeKey、不 activate：不搶焦點
    }

    static func dismiss() { current?.orderOut(nil); current?.close(); current = nil }
}
