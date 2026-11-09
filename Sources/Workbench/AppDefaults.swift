import Foundation

/// App 自己的設定（字型、模型清單、桌寵位置…）。
/// 用 --state-dir 開的測試 App 一律存到另一份（<bundle id>.test），測試怎麼切換都不會動到使用者平常用的那份。
let appDefaults: UserDefaults = {
    if CommandLine.arguments.contains("--state-dir"), let d = UserDefaults(suiteName: Edition.bundleID + ".test") { return d }
    return .standard
}()

/// E4B 每日檢討第一次啟用時的預設值；Prefs 可由使用者持久化覆寫。
enum AppDefaults {
    static let e4bDailyReviewEnabled = true
    static let lidResumeNotifyEnabled = true
    static let rightPanelDividerDefaultHeight: CGFloat = 220
    static let rightPanelDividerMinimumHeight: CGFloat = 90
    static let rightPanelDividerMaximumHeight: CGFloat = 560
}
