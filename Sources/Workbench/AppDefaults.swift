import Foundation

/// App 自己的設定（字型、模型清單、桌寵位置…）。
/// 用 --state-dir 開的測試 App 一律存到另一份（<bundle id>.test），測試怎麼切換都不會動到使用者平常用的那份。
let appDefaults: UserDefaults = {
    if CommandLine.arguments.contains("--state-dir"), let d = UserDefaults(suiteName: Edition.bundleID + ".test") { return d }
    return .standard
}()
