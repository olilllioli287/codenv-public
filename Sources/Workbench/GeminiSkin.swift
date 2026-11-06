import AppKit
import WebKit

// Gemini 網頁換皮（使用者 10/29：「Gemini 換皮」「這個就熱修，我有問題或網友有這問題就熱修」）：
// 只改外觀（背景、字型、顏色、使用者訊息、Gemini 回答、輸入框、模型選單），不動 Gemini 本身的功能。
// 做法跟隱藏歷史列表一樣：WKUserScript 注入 CSS，只在 gemini.google.com 生效（NotebookLM 不受影響）；設定頁有開關，預設關。
// 所有規則集中在下面的 blocks：Google 改版要熱修時只改這一處。每個區塊各自一個 <style>，選擇器對不上只會讓那一塊不生效；
// 選擇器盡量用 Gemini 的自訂元素名稱（user-query、model-response、rich-textarea…），不用會變的 class 雜湊。
// 這些選擇器都沒有在真的 Gemini 頁面驗證過（不能用使用者的帳號），只在本機假頁測過；有對不上的照使用者說的熱修。

enum GeminiSkin {
    static var on: Bool { appDefaults.object(forKey: "geminiSkin") as? Bool ?? false }

    /// 顏色變數：用 codenv 目前的主題代入（深色、淺色都跟著系統外觀），不寫死
    static func rootCSS(appearance: NSAppearance = NSApp.effectiveAppearance) -> String {
        let pal = Theme.fromITerm().palette(for: appearance)
        func hex(_ c: NSColor) -> String {
            // 轉不成 sRGB 的色（pattern、catalog）不能直接取 RGB 分量，會丟例外；退回中性灰
            guard let s = c.usingColorSpace(.sRGB) else { return "#808080" }
            return String(format: "#%02x%02x%02x", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
        }
        let accent = pal.ansi.count > 12 ? pal.ansi[12] : NSColor.controlAccentColor
        // 主色底上的字：accent 偏亮用深字、偏暗用白字（淺色主題的 accent 常偏亮，白字看不清楚）
        let acc = accent.usingColorSpace(.sRGB)
        let accLum = acc.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? 0.5
        let onAccent = accLum > 0.5 ? "#111111" : "#ffffff"
        return """
        :root {
          --cdv-bg: \(hex(pal.bg));
          --cdv-fg: \(hex(pal.fg));
          --cdv-accent: \(hex(accent));
          --cdv-on-accent: \(onAccent);
          --cdv-card: color-mix(in srgb, var(--cdv-fg) 4%, var(--cdv-bg));
          --cdv-border: color-mix(in srgb, var(--cdv-fg) 13%, var(--cdv-bg));
          --cdv-user-bg: color-mix(in srgb, var(--cdv-fg) 8%, var(--cdv-bg));
          --cdv-muted: color-mix(in srgb, var(--cdv-fg) 60%, var(--cdv-bg));
          --cdv-sans: -apple-system, BlinkMacSystemFont, "PingFang TC", "Heiti TC", "Helvetica Neue", sans-serif;
          --cdv-mono: ui-monospace, "SF Mono", Menlo, monospace;
        }
        """
    }

    /// 區塊：（名字，CSS）。名字會變成 <style id="codenv-skin-名字">，看網頁上哪一塊有沒有生效就看它
    static let blocks: [(name: String, css: String)] = [
        ("gem-tokens", """
        /* Gemini 核心設計變數覆蓋：全面映射至 codenv 主題色 */
        :root, body, .theme-host, .dark-theme, .theme-host.dark-theme {
          --gem-sys-color--surface: var(--cdv-bg) !important;
          --gem-sys-color--surface-dim: var(--cdv-bg) !important;
          --gem-sys-color--surface-bright: var(--cdv-card) !important;
          --gem-sys-color--surface-container: var(--cdv-card) !important;
          --gem-sys-color--surface-container-low: var(--cdv-card) !important;
          --gem-sys-color--surface-container-lowest: var(--cdv-bg) !important;
          --gem-sys-color--surface-container-high: color-mix(in srgb, var(--cdv-fg) 8%, var(--cdv-bg)) !important;
          --gem-sys-color--surface-container-highest: color-mix(in srgb, var(--cdv-fg) 11%, var(--cdv-bg)) !important;
          --gem-sys-color--surface-variant: color-mix(in srgb, var(--cdv-fg) 8%, var(--cdv-bg)) !important;
          --gem-sys-color--on-surface: var(--cdv-fg) !important;
          --gem-sys-color--on-surface-variant: var(--cdv-muted) !important;
          --gem-sys-color--on-surface-low: var(--cdv-muted) !important;
          --gem-sys-color--outline: var(--cdv-muted) !important;
          --gem-sys-color--outline-variant: var(--cdv-border) !important;
          --gem-sys-color--outline-low: var(--cdv-border) !important;
          --gem-sys-color--outline-solid-1: var(--cdv-border) !important;
          --gem-sys-color--outline-solid-2: var(--cdv-border) !important;
          --gem-sys-color--outline-solid-3: var(--cdv-border) !important;
          --gem-sys-color--primary: var(--cdv-accent) !important;
          --gem-sys-color--primary-emphasis-1: var(--cdv-accent) !important;
          --gem-sys-color--primary-emphasis-2: var(--cdv-accent) !important;
          --gem-sys-color--primary-fixed: var(--cdv-accent) !important;
          --gem-sys-color--primary-fixed-dim: var(--cdv-accent) !important;
          --gem-sys-color--blue-primary: var(--cdv-accent) !important;
          --gem-sys-color--on-primary: var(--cdv-on-accent) !important;
          --gem-sys-color--on-primary-emphasis-1: var(--cdv-on-accent) !important;
          --gem-sys-color--on-primary-fixed: var(--cdv-on-accent) !important;
          --gem-sys-color--on-primary-fixed-variant: var(--cdv-fg) !important;
          --gem-sys-color--on-primary-container: var(--cdv-fg) !important;
          --gem-sys-color--on-primary-container-emphasis-1: var(--cdv-fg) !important;
          --gem-sys-color--primary-container: color-mix(in srgb, var(--cdv-accent) 22%, var(--cdv-bg)) !important;
          --gem-sys-color--primary-container-emphasis-1: color-mix(in srgb, var(--cdv-accent) 26%, var(--cdv-bg)) !important;
          --gem-sys-color--primary-container-emphasis-2: color-mix(in srgb, var(--cdv-accent) 30%, var(--cdv-bg)) !important;
          --gem-sys-color--secondary: var(--cdv-muted) !important;
          --gem-sys-color--secondary-emphasis-1: var(--cdv-muted) !important;
          --gem-sys-color--secondary-emphasis-2: var(--cdv-muted) !important;
          --gem-sys-color--secondary-fixed: var(--cdv-muted) !important;
          --gem-sys-color--secondary-fixed-dim: var(--cdv-muted) !important;
          --gem-sys-color--secondary-container: color-mix(in srgb, var(--cdv-accent) 22%, var(--cdv-bg)) !important;
          --gem-sys-color--secondary-container-emphasis-1: color-mix(in srgb, var(--cdv-accent) 26%, var(--cdv-bg)) !important;
          --gem-sys-color--secondary-container-emphasis-2: color-mix(in srgb, var(--cdv-accent) 30%, var(--cdv-bg)) !important;
          --gem-sys-color--on-secondary: var(--cdv-on-accent) !important;
          --gem-sys-color--on-secondary-container: var(--cdv-fg) !important;
          --gem-sys-color--on-secondary-fixed: var(--cdv-on-accent) !important;
          --gem-sys-color--on-secondary-fixed-variant: var(--cdv-fg) !important;
          --gem-sys-color--inverse-surface: var(--cdv-fg) !important;
          --gem-sys-color--inverse-on-surface: var(--cdv-bg) !important;
          --gem-sys-color--inverse-primary: var(--cdv-accent) !important;
        }
        """),
        ("welcome", """
        /* 首頁（zero state）：清除漸層斑點裝飾與容器背景 */
        modular-zero-state,
        zero-state,
        .zero-state-container,
        zero-state-banners {
          background: transparent !important;
          background-color: transparent !important;
          box-shadow: none !important;
        }

        /* 載入動畫斑點淡化，限縮在 chat-loading-animation 內 */
        chat-loading-animation .nl-bg-blob,
        chat-loading-animation .nl-blob {
          display: none !important;
          opacity: 0 !important;
        }

        /* 隱藏首頁星星與問候標題（只限 modular-zero-state 範圍，保留建議晶片） */
        modular-zero-state assistant-messages-primary,
        modular-zero-state .assistant-messages-primary-container,
        modular-zero-state .lm-mobile-sparkle-and-text,
        modular-zero-state bard-logo,
        modular-zero-state [class*="sparkle"],
        modular-zero-state svg,
        modular-zero-state h1,
        modular-zero-state h2,
        modular-zero-state [class*="gds-display-"],
        modular-zero-state [class*="gds-headline-"] {
          display: none !important;
        }

        /* 建議按鈕／晶片卡片化 */
        zero-state-block-picker button,
        zero-state-block-picker [role="button"] {
          background-color: var(--cdv-card) !important;
          border: 1px solid var(--cdv-border) !important;
          color: var(--cdv-fg) !important;
          border-radius: 12px !important;
          font-size: 13.5px !important;
          font-family: var(--cdv-sans) !important;
          box-shadow: none !important;
        }

        zero-state-block-picker button:hover,
        zero-state-block-picker [role="button"]:hover {
          background-color: var(--cdv-user-bg) !important;
          border-color: var(--cdv-muted) !important;
          color: var(--cdv-fg) !important;
        }
        """),
        ("conversation", """
        /* 對話區置中與 800px 最大寬度（只設外層容器，不設 width:100%） */
        .conversation-container,
        .chat-container,
        chat-window-content,
        infinite-scroller,
        main .chat-history,
        [class*="conversation-container"] {
          max-width: 800px !important;
          margin-left: auto !important;
          margin-right: auto !important;
          box-sizing: border-box !important;
        }

        /* 使用者訊息宿主：display block 讓泡泡靠右，不設 width:100% */
        user-query {
          display: block !important;
          min-height: 0 !important;
          height: auto !important;
          padding-top: 0 !important;
          align-items: normal !important;
        }

        /* 清除 user-query 底下所有中介容器的背景與邊框，避免巢狀多層框疊加 */
        user-query [class*="bubble"],
        user-query .user-query-bubble,
        user-query .user-query-bubble-with-background,
        user-query .user-query-container,
        user-query .user-query-bubble-container,
        user-query [class*="query-container"],
        user-query user-query-content,
        user-query .user-query-content,
        user-query > div,
        .user-query-bubble,
        .user-query-container,
        user-query-content {
          background: transparent !important;
          background-color: transparent !important;
          border: 0 !important;
          box-shadow: none !important;
          padding: 0 !important;
          padding-top: 0 !important;
          min-height: 0 !important;
          height: auto !important;
          border-radius: 0 !important;
          max-width: none !important;
          align-items: normal !important;
        }

        /* 泡泡本身：僅在最內層文字元素 query-text 繪製單層泡泡 */
        user-query .query-text {
          display: block !important;
          flex: 0 0 auto !important;
          flex-shrink: 0 !important;
          width: fit-content !important;
          max-width: min(640px, 80vw) !important;
          margin-left: auto !important;
          margin-right: 0 !important;
          margin-top: 0 !important;
          margin-block-start: 0 !important;
          background: var(--cdv-user-bg) !important;
          background-color: var(--cdv-user-bg) !important;
          border-radius: 16px 16px 5px 16px !important;
          padding: 9px 14px !important;
          border: 0 !important;
          box-shadow: none !important;
          box-sizing: border-box !important;
          color: var(--cdv-fg) !important;
          font-family: var(--cdv-sans) !important;
          font-size: 15px !important;
          line-height: 1.6 !important;
          white-space: pre-wrap !important;
          word-break: normal !important;
          overflow-wrap: break-word !important;
        }

        /* 文字內部子孫元素維持純淨透明無邊框，清除頂部外邊距避免空白偏下 */
        user-query .query-text *,
        user-query .query-text p,
        user-query .query-text .query-text-line,
        user-query p,
        user-query .query-text-line {
          color: inherit !important;
          background: transparent !important;
          background-color: transparent !important;
          border: 0 !important;
          padding: 0 !important;
          padding-top: 0 !important;
          margin-top: 0 !important;
          margin-block-start: 0 !important;
        }

        /* Gemini 回答：透明底、行高 1.7、字級 15px、段落間距 10px */
        model-response,
        .model-response,
        [class*="model-response"] {
          background-color: transparent !important;
          background: transparent !important;
          color: var(--cdv-fg) !important;
          line-height: 1.7 !important;
          font-size: 15px !important;
          font-family: var(--cdv-sans) !important;
          box-shadow: none !important;
        }
        model-response p,
        .model-response p,
        [class*="model-response"] p {
          margin-top: 0 !important;
          margin-bottom: 10px !important;
          line-height: 1.7 !important;
          color: var(--cdv-fg) !important;
        }

        /* 程式碼區塊：等寬字 12.5px、卡片底色、邊框 1px、圓角 10px */
        model-response pre,
        model-response code,
        .model-response pre,
        .model-response code {
          font-family: var(--cdv-mono) !important;
          font-size: 12.5px !important;
          background-color: var(--cdv-card) !important;
          border: 1px solid var(--cdv-border) !important;
          border-radius: 10px !important;
        }
        model-response code:not(pre code),
        .model-response code:not(pre code) {
          padding: 2px 6px !important;
        }
        model-response pre,
        .model-response pre {
          padding: 12px 14px !important;
          line-height: 1.5 !important;
        }
        model-response pre code,
        .model-response pre code {
          border: 0 !important;
          background: transparent !important;
          background-color: transparent !important;
          border-radius: 0 !important;
          padding: 0 !important;
          font-size: inherit !important;
        }

        /* 表格與引用區塊 */
        model-response table,
        .model-response table {
          border-collapse: collapse !important;
          margin: 12px 0 !important;
          width: 100% !important;
        }
        model-response th,
        model-response td,
        .model-response th,
        .model-response td {
          border: 1px solid var(--cdv-border) !important;
          padding: 6px 12px !important;
        }
        model-response th,
        .model-response th {
          background-color: var(--cdv-card) !important;
        }
        model-response blockquote,
        .model-response blockquote {
          border-left: 3px solid var(--cdv-border) !important;
          margin: 10px 0 !important;
          padding: 4px 12px !important;
          color: var(--cdv-muted) !important;
        }

        /* 連結樣式 */
        model-response a,
        .model-response a {
          color: var(--cdv-accent) !important;
          text-decoration: underline !important;
        }

        /* 回答操作工具列（讚、複製、分享）：平常淡化 0.85，hover 時顯示 1 */
        model-response .response-actions,
        model-response .actions-container,
        model-response .message-actions,
        model-response [class*="response-action"],
        model-response [class*="bottom-action"],
        model-response action-buttons,
        .model-response .response-actions,
        .model-response .actions-container,
        .model-response .message-actions,
        .model-response [class*="response-action"],
        .model-response [class*="bottom-action"],
        .model-response action-buttons {
          opacity: 0.85 !important;
          transition: opacity 0.15s ease-in-out !important;
        }
        model-response .response-actions:hover,
        model-response .actions-container:hover,
        model-response .message-actions:hover,
        model-response [class*="response-action"]:hover,
        model-response [class*="bottom-action"]:hover,
        model-response action-buttons:hover,
        .model-response .response-actions:hover,
        .model-response .actions-container:hover,
        .model-response .message-actions:hover,
        .model-response [class*="response-action"]:hover,
        .model-response [class*="bottom-action"]:hover,
        .model-response action-buttons:hover {
          opacity: 1 !important;
        }
        """),
        ("input", """
        /* 輸入框外層容器透明化與置中 */
        input-container,
        .input-area-container,
        .input-area,
        .bottom-container,
        [class*="bottom-container"] {
          background: transparent !important;
          background-color: transparent !important;
          box-shadow: none !important;
          border: 0 !important;
          max-width: 800px !important;
          margin-left: auto !important;
          margin-right: auto !important;
        }

        /* 輸入框主體膠囊：圓角 16px、卡片底色與聚焦 accent 邊框 */
        input-area-v2 {
          background-color: var(--cdv-card) !important;
          border: 1px solid var(--cdv-border) !important;
          border-radius: 16px !important;
          box-shadow: none !important;
          transition: border-color 0.15s ease-in-out !important;
        }

        input-area-v2:focus-within {
          border-color: var(--cdv-accent) !important;
        }

        /* 膠囊內部各層一律透明無邊框（simplified-input-menu 為按鈕外層包裝，維持透明） */
        fieldset.input-area-fieldset,
        div.text-input-field.simplified-input-area,
        rich-textarea,
        rich-textarea.text-input-field_textarea,
        .text-input-field_textarea,
        .text-input-field_textarea-inner,
        .textarea-wrapper,
        .ql-editor,
        .leading-actions-wrapper,
        .trailing-actions-wrapper,
        simplified-input-menu {
          background: transparent !important;
          background-color: transparent !important;
          border: 0 !important;
          box-shadow: none !important;
        }

        /* 文字編輯區與游標 */
        .ql-editor,
        .ql-editor p {
          font-family: var(--cdv-sans) !important;
          font-size: 15px !important;
          line-height: 1.5 !important;
          color: var(--cdv-fg) !important;
          caret-color: var(--cdv-accent) !important;
        }

        /* Placeholder 樣式 */
        .ql-editor.ql-blank::before {
          color: var(--cdv-muted) !important;
          font-size: 15px !important;
          font-style: normal !important;
          font-family: var(--cdv-sans) !important;
        }

        /* 常態與無字時按鈕（＋、語音、無字時送出鈕）：透明底、muted 色 */
        gem-icon-button.menu-button,
        gem-icon-button.menu-button button,
        speech-dictation-mic-button,
        speech-dictation-mic-button button,
        .speech_dictation_mic_button,
        .speech-dictation-mic-button,
        .leading-actions-wrapper button,
        gem-icon-button.send-button:not(.has-input),
        gem-icon-button.send-button:not(.has-input) button,
        .trailing-actions-wrapper button:not(.has-input button):not(.has-input),
        input-area-v2 button:not(.has-input button):not(.has-input) {
          background: transparent !important;
          background-color: transparent !important;
          color: var(--cdv-muted) !important;
          border: 0 !important;
          box-shadow: none !important;
        }

        gem-icon-button.menu-button mat-icon,
        gem-icon-button.menu-button svg,
        speech-dictation-mic-button mat-icon,
        speech-dictation-mic-button svg,
        .speech_dictation_mic_button mat-icon,
        .speech_dictation_mic_button svg,
        .leading-actions-wrapper mat-icon,
        .leading-actions-wrapper svg,
        gem-icon-button.send-button:not(.has-input) mat-icon,
        gem-icon-button.send-button:not(.has-input) svg,
        .trailing-actions-wrapper gem-icon-button:not(.has-input) mat-icon,
        .trailing-actions-wrapper gem-icon-button:not(.has-input) svg {
          color: var(--cdv-muted) !important;
          fill: currentColor !important;
        }

        /* 送出按鈕有輸入時：accent 實心底色、保留圓形、圖示與字色為 on-accent */
        gem-icon-button.send-button.has-input {
          background-color: var(--cdv-accent) !important;
          background: var(--cdv-accent) !important;
          border-radius: 50% !important;
        }

        gem-icon-button.send-button.has-input button,
        gem-icon-button.send-button.has-input mat-icon,
        gem-icon-button.send-button.has-input svg,
        gem-icon-button.send-button.has-input path {
          background: transparent !important;
          background-color: transparent !important;
          color: var(--cdv-on-accent) !important;
          fill: currentColor !important;
        }

        /* ＋、麥克風按鈕 hover 效果（限制未停用狀態） */
        gem-icon-button.menu-button:not([disabled]):not([aria-disabled="true"]):hover,
        gem-icon-button.menu-button button:not([disabled]):not([aria-disabled="true"]):hover,
        speech-dictation-mic-button:not([disabled]):not([aria-disabled="true"]):hover,
        speech-dictation-mic-button button:not([disabled]):not([aria-disabled="true"]):hover,
        .speech_dictation_mic_button:not([disabled]):not([aria-disabled="true"]):hover,
        .leading-actions-wrapper button:not([disabled]):not([aria-disabled="true"]):hover,
        .trailing-actions-wrapper button:not(.has-input button):not(.has-input):not([disabled]):not([aria-disabled="true"]):hover,
        input-area-v2 button:not(.has-input button):not(.has-input):not([disabled]):not([aria-disabled="true"]):hover {
          color: var(--cdv-fg) !important;
        }

        gem-icon-button.menu-button:not([disabled]):not([aria-disabled="true"]):hover mat-icon,
        gem-icon-button.menu-button:not([disabled]):not([aria-disabled="true"]):hover svg,
        speech-dictation-mic-button:not([disabled]):not([aria-disabled="true"]):hover mat-icon,
        speech-dictation-mic-button:not([disabled]):not([aria-disabled="true"]):hover svg,
        .speech_dictation_mic_button:not([disabled]):not([aria-disabled="true"]):hover mat-icon,
        .speech_dictation_mic_button:not([disabled]):not([aria-disabled="true"]):hover svg,
        .leading-actions-wrapper button:not([disabled]):not([aria-disabled="true"]):hover mat-icon,
        .leading-actions-wrapper button:not([disabled]):not([aria-disabled="true"]):hover svg,
        .trailing-actions-wrapper button:not(.has-input button):not(.has-input):not([disabled]):not([aria-disabled="true"]):hover mat-icon,
        .trailing-actions-wrapper button:not(.has-input button):not(.has-input):not([disabled]):not([aria-disabled="true"]):hover svg {
          color: var(--cdv-fg) !important;
          fill: currentColor !important;
        }

        /* 隱藏輸入框下方免責宣告文字 */
        hallucination-disclaimer,
        .hallucination-disclaimer,
        :is(input-container, .input-area-container, .bottom-container) :is(.disclaimer, .disclaimer-text, [class*="disclaimer"], [class*="footnote"], .bottom-note, .input-footnote) {
          display: none !important;
        }
        """),
        ("model-menu", """
        /* 頁首模型選單：針對 bard-mode-switcher 縮小、無邊框、透明底、muted 字色 */
        bard-mode-switcher,
        bard-mode-switcher gem-button.logo-pill-btn,
        bard-mode-switcher button,
        [data-test-id="model-switcher"] {
          background-color: transparent !important;
          background: transparent !important;
          color: var(--cdv-muted) !important;
          border: 0 !important;
          border-radius: 8px !important;
          font-family: var(--cdv-sans) !important;
          font-size: 13px !important;
          padding: 2px 6px !important;
          box-shadow: none !important;
        }

        bard-mode-switcher:hover,
        bard-mode-switcher gem-button.logo-pill-btn:hover,
        bard-mode-switcher button:hover {
          color: var(--cdv-fg) !important;
          background-color: transparent !important;
        }

        bard-mode-switcher span.gds-body-m,
        bard-mode-switcher span.bard-text {
          font-family: var(--cdv-sans) !important;
          font-size: 13px !important;
          color: var(--cdv-muted) !important;
          -webkit-text-fill-color: var(--cdv-muted) !important;
        }

        bard-mode-switcher:hover span.gds-body-m,
        bard-mode-switcher:hover span.bard-text {
          color: var(--cdv-fg) !important;
          -webkit-text-fill-color: var(--cdv-fg) !important;
        }

        /* Gemini 字樣漸層改純色 */
        bard-mode-switcher span.bard-text.enable-aurora,
        span.bard-text.enable-aurora {
          background: none !important;
          background-image: none !important;
          -webkit-text-fill-color: var(--cdv-muted) !important;
          color: var(--cdv-muted) !important;
        }

        bard-mode-switcher:hover span.bard-text.enable-aurora {
          -webkit-text-fill-color: var(--cdv-fg) !important;
          color: var(--cdv-fg) !important;
        }

        bard-mode-switcher bard-logo,
        bard-mode-switcher svg {
          opacity: 0.6 !important;
        }

        bard-mode-switcher:hover bard-logo,
        bard-mode-switcher:hover svg {
          opacity: 0.9 !important;
        }

        /* 漢堡按鈕與頂欄按鈕 */
        side-nav-menu-button,
        side-nav-menu-button button {
          color: var(--cdv-muted) !important;
          background: transparent !important;
          border: 0 !important;
        }

        side-nav-menu-button:hover,
        side-nav-menu-button button:hover {
          color: var(--cdv-fg) !important;
        }

        /* 右側「登入」按鈕：accent 底色、on-accent 字色 */
        top-bar-actions .signed-out-buttons button,
        .signed-out-buttons button {
          background-color: var(--cdv-accent) !important;
          background: var(--cdv-accent) !important;
          color: var(--cdv-on-accent) !important;
          border: 0 !important;
          border-radius: 8px !important;
          font-family: var(--cdv-sans) !important;
          font-size: 13px !important;
          font-weight: 500 !important;
          box-shadow: none !important;
        }

        /* 浮動選單面板（模型選單、＋按鈕選單）：card 底色、邊框、圓角與陰影 */
        .cdk-overlay-pane mat-card.card-container,
        .cdk-overlay-pane .lm-bg,
        .mat-mdc-menu-panel {
          background-color: var(--cdv-card) !important;
          background: var(--cdv-card) !important;
          border: 1px solid var(--cdv-border) !important;
          border-radius: 12px !important;
          box-shadow: 0 6px 20px color-mix(in srgb, var(--cdv-fg) 22%, transparent) !important;
          color: var(--cdv-fg) !important;
        }

        /* 內層選單容器清除背景與外框，避免卡片內重複套框 */
        mat-card.card-container .lm-bg,
        .mat-mdc-menu-panel .lm-bg {
          border: 0 !important;
          box-shadow: none !important;
        }

        mat-action-list,
        mat-action-list[role="menu"],
        .cdk-overlay-pane mat-action-list,
        div[role="menu"],
        .cdk-overlay-pane [role="menu"] {
          background: transparent !important;
          background-color: transparent !important;
          border: 0 !important;
          box-shadow: none !important;
        }

        /* 選單項目樣式與 hover 效果 */
        .mat-mdc-menu-item,
        div[role="menu"] [role="menuitem"],
        [role="menuitem"],
        toolbox-drawer-item,
        toolbox-drawer-item button,
        mat-list-item {
          color: var(--cdv-fg) !important;
          font-family: var(--cdv-sans) !important;
          font-size: 13.5px !important;
        }

        .mat-mdc-menu-item:hover,
        div[role="menu"] [role="menuitem"]:hover,
        [role="menuitem"]:hover,
        .mat-mdc-menu-item.cdk-focused,
        toolbox-drawer-item:hover,
        toolbox-drawer-item button:hover,
        mat-list-item:hover {
          background-color: var(--cdv-user-bg) !important;
          color: var(--cdv-fg) !important;
        }
        """),
        ("sidenav", """
        /* 全域底色、字型與容器透明度處理（修復頂端 136px 白條） */
        html,
        body {
          background-color: var(--cdv-bg) !important;
          color: var(--cdv-fg) !important;
          font-family: var(--cdv-sans) !important;
        }

        bard-sidenav-container,
        bard-sidenav-content,
        mat-sidenav-container,
        mat-sidenav-content,
        side-navigation-content,
        chat-window,
        chat-window-content,
        infinite-scroller,
        .conversation-container,
        main {
          background-color: var(--cdv-bg) !important;
          color: var(--cdv-fg) !important;
          font-family: var(--cdv-sans) !important;
        }

        header,
        bard-app-bar,
        .app-bar,
        [class*="app-bar"] {
          background-color: var(--cdv-bg) !important;
          border-bottom: 1px solid var(--cdv-border) !important;
          box-shadow: none !important;
        }

        /* 側邊欄背景與右邊框 */
        bard-sidenav,
        .mat-drawer {
          background-color: var(--cdv-bg) !important;
          border-right: 1px solid var(--cdv-border) !important;
          font-family: var(--cdv-sans) !important;
        }

        /* 側邊欄導航與歷史紀錄項目：字級 13.5px */
        bard-sidenav a,
        bard-sidenav button,
        [class*="sidenav"] [role="button"],
        [class*="conversation-title"],
        .conversation-item {
          font-size: 13.5px !important;
          color: var(--cdv-fg) !important;
          border-radius: 8px !important;
        }

        /* 側欄項目 hover 與選中：底色 --cdv-user-bg，移除彩色強調 */
        bard-sidenav a:hover,
        bard-sidenav button:hover,
        [class*="conversation-item"]:hover,
        [class*="sidenav-item"]:hover {
          background-color: var(--cdv-user-bg) !important;
          color: var(--cdv-fg) !important;
        }
        bard-sidenav .selected,
        bard-sidenav [aria-selected="true"],
        bard-sidenav .active,
        [class*="conversation-item"][class*="active"],
        [class*="conversation-item"][class*="selected"] {
          background-color: var(--cdv-user-bg) !important;
          color: var(--cdv-fg) !important;
          font-weight: 500 !important;
          border: none !important;
        }
        """),
    ]

    private static var appearanceObserver: NSKeyValueObservation?
    /// App 外觀變了（設定頁換淺色／深色／跟系統、系統自己天黑切換）：顏色變數是用目前外觀代入的，要重新代入。
    /// 換皮開著才需要：重裝腳本（之後新開的頁拿到新的顏色）並對已經開著的頁重套
    static func startObservingAppearance() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: []) { _, _ in
            DispatchQueue.main.async { if on { BrowserPane.setSkin(true) }; if NotebookSkin.on { BrowserPane.setNotebookSkin(true) } }
        }
    }

    static func script(on: Bool) -> WKUserScript {
        buildScript(hosts: ["gemini.google.com"], key: "", anyHost: GeminiExport.anyHost, blocks: blocks, vars: rootCSS(), on: on)
    }

    /// 已經開著的頁面：直接改變數、重套（開關、換外觀時）
    static func applyJS(on: Bool) -> String { applyJS(key: "", vars: rootCSS(), on: on) }

    /// 換皮腳本的共用做法（NotebookSkin.swift 也用）：hosts＝只在這些網址主機生效（anyHost＝測試旗標，任何網頁都算；NotebookLM 固定給 false）；key＝全域變數的後綴（Gemini 空字串，各家不互相干擾）
    static func buildScript(hosts: [String], key: String, anyHost: Bool, blocks: [(name: String, css: String)], vars varsCSS: String, on: Bool) -> WKUserScript {
        func json(_ o: Any, _ opts: JSONSerialization.WritingOptions = []) -> String {
            (try? JSONSerialization.data(withJSONObject: o, options: opts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        let arr = blocks.map { ["name": $0.name, "css": $0.css] }
        let vars = json([varsCSS])
        let js = skinJS.replacingOccurrences(of: "__ANY__", with: anyHost ? "true" : "false")
            .replacingOccurrences(of: "__HOSTS__", with: json(hosts))
            .replacingOccurrences(of: "__K__", with: key)
            .replacingOccurrences(of: "__ON__", with: on ? "true" : "false")
            .replacingOccurrences(of: "__VARS__", with: String(vars.dropFirst().dropLast()))
            .replacingOccurrences(of: "__BLOCKS__", with: json(arr))
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static func applyJS(key: String, vars varsCSS: String, on: Bool) -> String {
        let vars = (try? JSONSerialization.data(withJSONObject: [varsCSS])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return "window.__codenvSkinOn\(key) = \(on); window.__codenvSkinVars\(key) = \(vars)[0]; window.__codenvApplySkin\(key) && window.__codenvApplySkin\(key)()"
    }

    static let skinJS = #"""
    (function () {
      if (!(__HOSTS__.indexOf(location.hostname) >= 0 || __ANY__)) return;
      window.__codenvSkinOn__K__ = __ON__;
      window.__codenvSkinVars__K__ = __VARS__;
      if (window.__codenvSkinInstalled__K__) { if (window.__codenvApplySkin__K__) window.__codenvApplySkin__K__(); return; }
      window.__codenvSkinInstalled__K__ = true;
      var BLOCKS = __BLOCKS__;
      var VARS_ID = 'codenv-skin-vars__K__';
      function put(id, css) {
        var st = document.getElementById(id);
        if (!st) { st = document.createElement('style'); st.id = id; (document.head || document.documentElement).appendChild(st); }
        if (st.textContent !== css) st.textContent = css;
      }
      var IDS = [VARS_ID].concat(BLOCKS.map(function (b) { return 'codenv-skin-' + b.name; }));
      function leftovers() { return IDS.some(function (i) { return !!document.getElementById(i); }); }
      function apply() {
        if (!window.__codenvSkinOn__K__) { IDS.forEach(function (i) { var s = document.getElementById(i); if (s) s.remove(); }); return; }
        put(VARS_ID, window.__codenvSkinVars__K__ || '');
        BLOCKS.forEach(function (b) { put('codenv-skin-' + b.name, b.css); });
      }
      window.__codenvApplySkin__K__ = apply;
      apply();
      document.addEventListener('DOMContentLoaded', apply);
      new MutationObserver(function () {
        // 開著：樣式被頁面重建弄丟就補回；關著：有殘留（重建 DOM 時搬進來的、關閉當下頁面還沒初始化）就清掉
        if (window.__codenvSkinOn__K__ ? !document.getElementById(VARS_ID) : leftovers()) apply();
      }).observe(document.documentElement, { childList: true });
    })();
    """#
}
