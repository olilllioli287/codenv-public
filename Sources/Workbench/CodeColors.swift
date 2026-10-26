import SwiftUI
import AppKit

/// 對話裡程式碼區塊的顏色（⌘ , 外觀頁「程式碼顏色」）。七類：關鍵字、型別、函式、字串、數字、屬性、註解
enum CodeColors {
    static let kinds: [(key: String, name: String)] = [
        ("keyword", L("關鍵字（import、class、let）")), ("type", L("型別、類別名稱")), ("function", L("函式名稱")),
        ("string", L("字串")), ("number", L("數字、常數")), ("attr", L("屬性、參數名稱")), ("comment", L("註解")),
    ]
    static let schemes: [(id: String, name: String)] = [
        ("claude", L("跟 Claude Code 終端機一樣")), ("iterm", L("iTerm 原本的對應")),
        ("github", "GitHub Dark"), ("monokai", "Monokai"), ("dracula", "Dracula"), ("custom", L("自訂")),
    ]

    /// 這個配色在目前（深／淺色）調色盤下的實際顏色；nil＝不另外指定（畫面照 iTerm 的 ANSI 對應）
    static func resolve(_ scheme: String, palette p: Palette, dark: Bool) -> [String: String]? {
        func a(_ i: Int) -> String { p.ansi.count > i ? p.ansi[i].hex : "#888888" }
        switch scheme {
        case "iterm": return nil
        case "claude":
            // Claude Code 在終端機的 dark-ansi 主題：關鍵字亮紫、型別黃、函式青、字串綠、數字黃、屬性跟文字一樣、註解灰
            return dark
                ? ["keyword": a(13), "type": a(11), "function": a(14), "string": a(10), "number": a(11), "attr": p.fg.hex, "comment": a(8)]
                : ["keyword": a(5), "type": a(3), "function": a(6), "string": a(2), "number": a(3), "attr": p.fg.hex, "comment": a(8)]
        case "github":
            return ["keyword": "#FF7B72", "type": "#FFA657", "function": "#D2A8FF", "string": "#A5D6FF", "number": "#79C0FF", "attr": "#79C0FF", "comment": "#8B949E"]
        case "monokai":
            return ["keyword": "#F92672", "type": "#66D9EF", "function": "#A6E22E", "string": "#E6DB74", "number": "#AE81FF", "attr": "#FD971F", "comment": "#75715E"]
        case "dracula":
            return ["keyword": "#FF79C6", "type": "#8BE9FD", "function": "#50FA7B", "string": "#F1FA8C", "number": "#BD93F9", "attr": "#FFB86C", "comment": "#6272A4"]
        default:
            let c = Prefs.shared.customCode
            return c.isEmpty ? resolve("claude", palette: p, dark: dark) : c
        }
    }

    /// 給畫面的 JS：wb.setCodeColors({...}) 或 null
    static func js(palette: Palette, dark: Bool) -> String {
        guard let m = resolve(Prefs.shared.codeScheme, palette: palette, dark: dark),
              let d = try? JSONSerialization.data(withJSONObject: m), let s = String(data: d, encoding: .utf8) else { return "wb.setCodeColors(null)" }
        return "wb.setCodeColors(\(s))"
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// 外觀頁的「程式碼顏色」那一區：選配色、每一類可以自己改、下面一段預覽
struct CodeColorsSection: View {
    @ObservedObject var p = Prefs.shared
    @Environment(\.colorScheme) private var scheme

    /// iTerm 的設定檔只讀一次（以前每畫一次要讀幾十次，拖顏色時會卡）
    private static let iterm = Theme.fromITerm()
    private var palette: Palette { scheme == .dark ? Self.iterm.dark : Self.iterm.light }
    private var current: [String: String] {
        CodeColors.resolve(p.codeScheme, palette: palette, dark: scheme == .dark)
            ?? CodeColors.resolve("claude", palette: palette, dark: scheme == .dark) ?? [:]
    }
    private func color(_ k: String, in m: [String: String]) -> Color { Color(nsColor: NSColor(hex: m[k] ?? "") ?? .labelColor) }

    var body: some View {
        let cur = current
        return Section(L("程式碼顏色（對話裡的程式碼區塊）")) {
            Picker(L("配色"), selection: $p.codeScheme) {
                ForEach(CodeColors.schemes, id: \.id) { s in Text(s.name).tag(s.id) }
            }
            ForEach(CodeColors.kinds, id: \.key) { k in
                ColorPicker(k.name, selection: Binding(get: { color(k.key, in: cur) }, set: { c in
                    // 改任何一個就變成「自訂」（從目前的配色複製一份再改）
                    var m = current
                    let hex = NSColor(c).hex
                    guard m[k.key] != hex else { return }
                    m[k.key] = hex
                    p.customCode = m
                    if p.codeScheme != "custom" { p.codeScheme = "custom" }
                }), supportsOpacity: false)
            }
            preview(cur)
        }
    }

    private func preview(_ cur: [String: String]) -> some View {
        let bg = Color(nsColor: palette.bg), fg = Color(nsColor: palette.fg)
        func t(_ s: String, _ k: String?) -> Text { Text(s).foregroundColor(k.map { color($0, in: cur) } ?? fg) }
        let mono = Font.system(size: 13, design: .monospaced)
        return VStack(alignment: .leading, spacing: 3) {
            (t("import", "keyword") + t(" AppKit", nil)).font(mono)
            (t("// 新對話的預設模型", "comment")).font(mono)
            (t("final class ", "keyword") + t("Prefs", "type") + t(": ", nil) + t("ObservableObject", "type") + t(" {", nil)).font(mono)
            (t("    static let ", "keyword") + t("limit", "attr") + t(" = ", nil) + t("400", "number")).font(mono)
            (t("    func ", "keyword") + t("load", "function") + t("(", nil) + t("name", "attr") + t(": ", nil) + t("String", "type") + t(") { ", nil) + t("print", "function") + t("(", nil) + t("\"你好\"", "string") + t(") }", nil)).font(mono)
            t("}", nil).font(mono)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(bg))
    }
}
