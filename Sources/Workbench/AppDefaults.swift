import CryptoKit
import Foundation

/// App 自己的設定（字型、模型清單、桌寵位置…）。
/// 用 --state-dir 開的測試 App 以狀態目錄雜湊固定 suite，讓同一測試目錄重開時保留偏好。
let appDefaults: UserDefaults = {
    guard let suiteName = AppDefaults.testSuiteName else { return .standard }
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("無法建立隔離的測試偏好 suite：\(suiteName)")
    }
    return defaults
}()

/// E4B 每日檢討第一次啟用時的預設值；Prefs 可由使用者持久化覆寫。
enum AppDefaults {
    /// 同一個 --state-dir 重複啟動會使用同一 suite；不同目錄以雜湊隔離。
    static let testSuiteName: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--state-dir") else { return nil }
        let rawPath = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--")
            ? arguments[index + 1]
            : "<missing-state-dir>"
        let path = URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return Edition.bundleID + ".test." + String(digest.prefix(32))
    }()

    static let e4bDailyReviewEnabled = true
    static let lidResumeNotifyEnabled = true
    static let rightPanelDividerDefaultHeight: CGFloat = 220
    static let rightPanelDividerMinimumHeight: CGFloat = 90
    static let rightPanelDividerMaximumHeight: CGFloat = 560
}
