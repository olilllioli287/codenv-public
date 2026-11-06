import AppKit
import WebKit

// NotebookLM（Gemini Notebook）網頁換皮：做法跟 GeminiSkin.swift 一樣——WKUserScript 注入 CSS，只改外觀、不動功能，
// 設定頁有開關（預設關），規則集中在下面的 blocks，Google 改版失效就熱修。
// 跟 Gemini 不一樣的地方：NotebookLM 的顏色全部走設計變數（--nb-sys-color--*、--gm3-sys-color-*，2026/10 從公開的首頁 HTML 看到的），
// 所以主要做法是把這些變數換成 codenv 主題色，不靠會變的元素名稱或 class；首頁和筆記本內頁用同一組變數，一起換。
// 網址主機：notebooklm.google.com 會轉到 notebook.google.com，兩個都收。
// 變數名稱只有看過公開首頁（沒登入），登入後的內頁（來源欄、聊天、工作室）用到哪些變數沒有驗證；有沒換到的就照使用者說的熱修。

enum NotebookSkin {
    static var on: Bool { appDefaults.object(forKey: "notebookSkin") as? Bool ?? false }
    static let hosts = GeminiExport.notebookHosts

    /// 顏色變數：沿用 GeminiSkin 的 --cdv-*（codenv 主題色，跟著淺色／深色），再加上 color-scheme 讓捲軸、表單控制項跟著
    static func rootCSS(appearance: NSAppearance = NSApp.effectiveAppearance) -> String {
        let pal = Theme.fromITerm().palette(for: appearance)
        // 轉不成 sRGB 就當深色（不對原色取 RGB 分量，非 RGB 色會丟例外）
        let dark = pal.bg.usingColorSpace(.sRGB).map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent < 0.5 } ?? true
        // 商標圖（img 的網址帶 /branding/…/light_mode/ 或 /dark_mode/）是照 Google 自己的明暗模式選的；codenv 主題的明暗不一樣時，把那張反相才看得到
        let invert = "invert(1) hue-rotate(180deg)"
        return GeminiSkin.rootCSS(appearance: appearance) + """

        :root { color-scheme: \(dark ? "dark" : "light"); --cdv-logo-light-filter: \(dark ? invert : "none"); --cdv-logo-dark-filter: \(dark ? "none" : invert); }
        """
    }

    /// 變數要蓋掉 Google 在 .luminous-ui、:root、body、.dark-mode／.dark-theme 上各定義一次的值，所以這幾個選擇器都列，再加 !important
    private static let scopes = ":root, body, .luminous-ui, .dark-mode, .dark-theme, .luminous-ui .dark-mode, .luminous-ui .dark-theme, body.luminous-ui"

    static let blocks: [(name: String, css: String)] = [
        ("nlm-tokens", """
        /* NotebookLM 自己的顏色變數 → codenv 主題色 */
        \(scopes) {
          --nb-sys-color--surface-background: var(--cdv-bg) !important;
          --nb-sys-color--surface: var(--cdv-bg) !important;
          --nb-sys-color--surface-dim: color-mix(in srgb, var(--cdv-fg) 3%, var(--cdv-bg)) !important;
          --nb-sys-color--surface-bright: var(--cdv-card) !important;
          --nb-sys-color--surface-accent: color-mix(in srgb, var(--cdv-accent) 22%, var(--cdv-bg)) !important;
          --nb-sys-color--on-surface: var(--cdv-fg) !important;
          --nb-sys-color--on-surface-variant: var(--cdv-muted) !important;
          --nb-sys-color--on-surface-low: color-mix(in srgb, var(--cdv-fg) 12%, transparent) !important;
          --nb-sys-color--code-background: var(--cdv-card) !important;
          --nb-sys-color-states--hover-on-surface: color-mix(in srgb, var(--cdv-fg) 8%, transparent) !important;
          --nb-sys-color-states--focus-on-surface: color-mix(in srgb, var(--cdv-fg) 10%, transparent) !important;
          --nb-sys-color-states--pressed-on-surface: color-mix(in srgb, var(--cdv-fg) 12%, transparent) !important;
          --nb-sys-color-acc-color--accent: var(--cdv-accent) !important;
          --nb-sys-color-acc-color--accent-container: color-mix(in srgb, var(--cdv-accent) 24%, var(--cdv-bg)) !important;
        }
        """),
        ("nlm-gm3", """
        /* Google Material 3 的共用變數（選單、對話框、按鈕、輸入框用得到） */
        \(scopes) {
          --gm3-sys-color-background: var(--cdv-bg) !important;
          --gm3-sys-color-surface-container: var(--cdv-card) !important;
          --gm3-sys-color-surface-container-high: color-mix(in srgb, var(--cdv-fg) 8%, var(--cdv-bg)) !important;
          --gm3-sys-color-on-surface: var(--cdv-fg) !important;
          --gm3-sys-color-on-surface-variant: var(--cdv-muted) !important;
          --gm3-sys-color-outline: var(--cdv-muted) !important;
          --gm3-sys-color-outline-variant: var(--cdv-border) !important;
          --gm3-sys-color-primary: var(--cdv-accent) !important;
          --gm3-sys-color-secondary-container: color-mix(in srgb, var(--cdv-accent) 24%, var(--cdv-bg)) !important;
          --gm3-sys-color-on-secondary-container: var(--cdv-fg) !important;
        }
        """),
        ("nlm-cta", """
        /* 主行動按鈕（CTA / Filled Button）底色與高對比文字 */
        \(scopes) {
          --nlm-cta-text-and-icon-primary: var(--cdv-on-accent) !important;
          --nlm-ctas-buttons-primary: var(--cdv-accent) !important;
          --nlm-button-fills-primary: var(--cdv-accent) !important;
          --nlm-button-fills-primary-hover: color-mix(in srgb, var(--cdv-accent) 85%, var(--cdv-fg)) !important;
          --mat-button-filled-label-text-color: var(--cdv-on-accent) !important;
          --mat-button-filled-container-color: var(--cdv-accent) !important;
        }
        .mat-mdc-unelevated-button:not([disabled]),
        .mdc-button--unelevated:not([disabled]),
        button[mat-flat-button],
        .mat-mdc-unelevated-button:not([disabled]) .mdc-button__label,
        .mdc-button--unelevated:not([disabled]) .mdc-button__label,
        button[mat-flat-button] .mdc-button__label,
        .mat-mdc-unelevated-button:not([disabled]) mat-icon,
        .mdc-button--unelevated:not([disabled]) mat-icon,
        button[mat-flat-button] mat-icon {
          color: var(--cdv-on-accent) !important;
          -webkit-text-fill-color: var(--cdv-on-accent) !important;
        }
        """),
        ("nlm-font", """
        /* 字型：NotebookLM 把無襯線字型放在 --nlm-font-family-sans；圖示字型（Luminous／Material Symbols）不碰 */
        \(scopes) { --nlm-font-family-sans: var(--cdv-sans) !important; }
        body { font-family: var(--cdv-sans); }
        pre, code, .code-block { font-family: var(--cdv-mono); }
        """),
        ("nlm-logo", """
        /* 商標圖跟著 codenv 明暗 */
        img[src*="/branding/"][src*="/light_mode/"] { filter: var(--cdv-logo-light-filter) !important; }
        img[src*="/branding/"][src*="/dark_mode/"] { filter: var(--cdv-logo-dark-filter) !important; }
        """),
        ("nlm-misc", """
        /* 小地方：選取文字、游標、捲軸跟 codenv 一致 */
        ::selection { background: color-mix(in srgb, var(--cdv-accent) 35%, transparent); }
        input, textarea, [contenteditable="true"] { caret-color: var(--cdv-accent); }
        * { scrollbar-color: color-mix(in srgb, var(--cdv-fg) 28%, var(--cdv-bg)) transparent; }
        """),
    ]

    static func script(on: Bool) -> WKUserScript {
        GeminiSkin.buildScript(hosts: hosts, key: "Nlm", anyHost: false, blocks: blocks, vars: rootCSS(), on: on)
    }
    static func applyJS(on: Bool) -> String { GeminiSkin.applyJS(key: "Nlm", vars: rootCSS(), on: on) }
}
