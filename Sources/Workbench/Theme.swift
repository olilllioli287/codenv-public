import AppKit
import SwiftTerm

/// 一組配色（淺色或深色模式各一組）
struct Palette {
    var fg, bg, cursor, selection, bold: NSColor
    var ansi: [NSColor]   // 16 色

    /// 把終端機一格的顏色換成實際的顏色（256 色、全彩、預設前景／背景）。
    /// 規則照 SwiftTerm 的 mapColor：「預設」用在文字就是文字色、用在背景就是背景色；「反轉的預設」兩者對調
    func color(_ c: Attribute.Color, isFg: Bool, bold isBold: Bool = false) -> NSColor {
        switch c {
        // 粗體的預設文字色跟一般文字一樣（SwiftTerm 就是這樣畫的；閱讀層要一致，切換時才不會變色）
        case .defaultColor: return isFg ? fg : bg
        case .defaultInvertedColor: return isFg ? bg : fg
        case .trueColor(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .ansi256(let code):
            var i = Int(code)
            if i < 8 && isBold { i += 8 }   // 粗體用亮色（跟 SwiftTerm 的 useBrightColors 一樣）
            if i < 16 { return ansi[i] }
            if i < 232 {
                let n = i - 16
                func level(_ v: Int) -> CGFloat { v == 0 ? 0 : CGFloat(55 + v * 40) / 255 }
                return NSColor(srgbRed: level(n / 36), green: level((n / 6) % 6), blue: level(n % 6), alpha: 1)
            }
            let g = CGFloat(8 + (i - 232) * 10) / 255
            return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
        }
    }
}

/// 字型和配色。預設從 iTerm 的預設設定檔匯入（淺色、深色兩組，跟著系統外觀切換）
struct Theme {
    var font: NSFont
    var boldFont: NSFont
    var lineSpacing: CGFloat
    var light: Palette
    var dark: Palette

    func palette(for appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    static func fromITerm() -> Theme {
        let fallbackFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        var theme = Theme(font: fallbackFont, boldFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold), lineSpacing: 1,
                          light: defaultLight, dark: defaultDark)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let profiles = root["New Bookmarks"] as? [[String: Any]], !profiles.isEmpty else { return theme }
        let guid = root["Default Bookmark Guid"] as? String
        let p = profiles.first { $0["Guid"] as? String == guid } ?? profiles[0]

        // "Sarasa-Term-TC-SemiBold 20"：最後一段是大小
        if let spec = p["Normal Font"] as? String, let space = spec.lastIndex(of: " "),
           let size = Double(spec[spec.index(after: space)...]),
           let f = NSFont(name: String(spec[..<space]), size: CGFloat(size)) {
            theme.font = f
            theme.boldFont = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        }
        if let v = p["Vertical Spacing"] as? Double { theme.lineSpacing = CGFloat(v) }

        func color(_ key: String) -> NSColor? {
            guard let d = p[key] as? [String: Any] else { return nil }
            let r = CGFloat(d["Red Component"] as? Double ?? 0), g = CGFloat(d["Green Component"] as? Double ?? 0)
            let b = CGFloat(d["Blue Component"] as? Double ?? 0), a = CGFloat(d["Alpha Component"] as? Double ?? 1)
            switch d["Color Space"] as? String {
            case "P3": return NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
            case "Calibrated": return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
            default: return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            }
        }
        func palette(_ suffix: String, base: Palette) -> Palette {
            var pal = base
            if let c = color("Foreground Color\(suffix)") { pal.fg = c }
            if let c = color("Background Color\(suffix)") { pal.bg = c }
            if let c = color("Cursor Color\(suffix)") { pal.cursor = c }
            if let c = color("Selection Color\(suffix)") { pal.selection = c }
            pal.bold = color("Bold Color\(suffix)") ?? pal.fg
            for i in 0..<16 { if let c = color("Ansi \(i) Color\(suffix)") { pal.ansi[i] = c } }
            return pal
        }
        if p["Use Separate Colors for Light and Dark Mode"] as? Bool == true {
            theme.light = palette(" (Light)", base: defaultLight)
            theme.dark = palette(" (Dark)", base: defaultDark)
        } else {
            theme.light = palette("", base: defaultLight)
            theme.dark = theme.light
        }
        return theme
    }

    static let xterm16: [NSColor] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ].map { NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
    static let defaultLight = Palette(fg: .black, bg: .white, cursor: .black, selection: .selectedTextBackgroundColor, bold: .black, ansi: xterm16)
    static let defaultDark = Palette(fg: NSColor(white: 0.86, alpha: 1), bg: NSColor(white: 0.08, alpha: 1), cursor: .white,
                                     selection: .selectedTextBackgroundColor, bold: .white, ansi: xterm16)
}

extension NSColor {
    /// SwiftTerm 的調色盤用 16 位元的 RGB
    var terminalColor: SwiftTerm.Color {
        let c = usingColorSpace(.sRGB) ?? self
        func v(_ x: CGFloat) -> UInt16 { UInt16(max(0, min(1, x)) * 65535) }
        return SwiftTerm.Color(red: v(c.redComponent), green: v(c.greenComponent), blue: v(c.blueComponent))
    }
}
