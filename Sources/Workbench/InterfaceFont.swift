import AppKit
import SwiftUI

/// 介面字型。空白或找不到字型時回到系統字型；終端機和程式碼仍走各自的等寬設定。
enum InterfaceFont {
    static let defaultPostScriptName = "CilantroCodeMono-Regular"
    static let legacyDefaultPostScriptName = "NiYu-Regular"

    static var postScriptName: String { Prefs.shared.interfaceFont.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func font(size: CGFloat) -> NSFont? {
        let name = postScriptName
        guard !name.isEmpty else { return nil }
        return NSFont(name: name, size: size)
    }

    static var isAvailable: Bool { font(size: 13) != nil }
    static var resolvedFont: NSFont? { font(size: 15) }
    static var effectiveFamily: String {
        guard let resolved = font(size: 13) else { return "system" }
        return postScriptName == defaultPostScriptName ? "Cilantro Code Mono" : (resolved.familyName ?? "system")
    }
    static func swiftUIFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard design == .default, let resolved = font(size: size) else {
            return .system(size: size, weight: weight, design: design)
        }
        return .custom(resolved.fontName, size: size).weight(weight)
    }
    static func swiftUIFont(for rawName: String) -> Font? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let font = NSFont(name: name, size: NSFont.systemFontSize) else { return nil }
        return .custom(font.fontName, size: NSFont.systemFontSize)
    }

    /// 啟動時先查一次字型目錄；查不到時讓各畫面使用系統字型，不顯示錯誤或等待。
    static func checkAtLaunch() { _ = isAvailable }
}
