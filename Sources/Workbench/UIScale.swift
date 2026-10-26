import SwiftUI
import Combine

/// 整體文字大小（對話內容、輸入框、側欄、用量欄、分頁列）。顯示方式選單：放大 ⌘ =、縮小 ⌘ -、實際大小 ⌘ 0
final class UIScale: ObservableObject {
    static let shared = UIScale()
    static let defaultFactor = 1.15            // 使用者覺得字小：預設就放大一點
    @Published var factor: Double { didSet { appDefaults.set(factor, forKey: "uiScale") } }
    private init() { factor = appDefaults.object(forKey: "uiScale") as? Double ?? UIScale.defaultFactor }
    func bigger() { factor = min(2.0, (factor + 0.1) * 100 / 100) }
    func smaller() { factor = max(0.8, factor - 0.1) }
    func reset() { factor = UIScale.defaultFactor }
    var f: CGFloat { CGFloat(factor) }
}

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var uiScale: CGFloat { get { self[UIScaleKey.self] } set { self[UIScaleKey.self] = newValue } }
}

/// 把目前的文字大小傳給底下的 SwiftUI 畫面（改了就整塊重畫）
struct Scaled<Content: View>: View {
    @ObservedObject private var scale = UIScale.shared
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View { content.environment(\.uiScale, scale.f) }
}
