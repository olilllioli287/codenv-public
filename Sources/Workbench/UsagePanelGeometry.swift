import AppKit
import CoreGraphics

/// F12 額度面板的純幾何計算：依螢幕可見區、父視窗與 uiScale 決定欄數、面板專用縮放倍率、寬度與 clamp 後位置。
enum UsagePanelGeometry {
    static let screenHorizontalMargin: CGFloat = 24
    static let minShrunkScale: CGFloat = 1.0
    static let remeasureWidthTolerance: CGFloat = 0.5
    static let remeasureScaleTolerance: CGFloat = 0.0001

    /// `UsagePanelGeometry.layout` 的純幾何計算結果。
    struct Layout: Equatable {
        let columns: Int
        let panelScale: CGFloat
        let panelWidth: CGFloat
        let originX: CGFloat
        let originY: CGFloat

        init(
            columns: Int,
            panelScale: CGFloat,
            panelWidth: CGFloat,
            originX: CGFloat = 0,
            originY: CGFloat = 0
        ) {
            self.columns = columns
            self.panelScale = panelScale
            self.panelWidth = panelWidth
            self.originX = originX
            self.originY = originY
        }
    }

    /// 判斷新計算的面板幾何相較於上次套用的幾何是否真的改變了欄數、寬度或縮放倍率。
    /// 僅比對兩次算出的 `Layout`（忽略 `originX`／`originY` 與 AppKit 實際視窗寬度）；
    /// 系統因實體螢幕較窄限縮視窗寬度時，只要算出的幾何不變就不應重設量測就緒旗標。
    static func needsRemeasure(previous: Layout?, next: Layout) -> Bool {
        guard let previous else { return true }
        if previous.columns != next.columns { return true }
        if !previous.panelWidth.isFinite || !next.panelWidth.isFinite
            || abs(previous.panelWidth - next.panelWidth) > remeasureWidthTolerance {
            return true
        }
        if !previous.panelScale.isFinite || !next.panelScale.isFinite
            || abs(previous.panelScale - next.panelScale) > remeasureScaleTolerance {
            return true
        }
        return false
    }

    /// 指定欄數與縮放倍率下，面板視窗需要的總寬度（含左右 padding 與捲軸保留寬）。
    static func panelWidth(columns: Int, scale: CGFloat) -> CGFloat {
        UsageFullPage.width(columns: columns, scale: scale) + UsageFullPage.scrollReserve * scale
    }

    /// 螢幕可見區退回順序：父視窗所在螢幕 → `NSScreen.main` → `NSScreen.screens.first` → 父視窗自身 frame。
    static func resolveVisibleFrame(
        windowScreenFrame: CGRect?,
        mainScreenFrame: CGRect?,
        firstScreenFrame: CGRect?,
        parentFrame: CGRect
    ) -> CGRect {
        if let frame = windowScreenFrame, frame.width > 0, frame.height > 0 { return frame }
        if let frame = mainScreenFrame, frame.width > 0, frame.height > 0 { return frame }
        if let frame = firstScreenFrame, frame.width > 0, frame.height > 0 { return frame }
        return parentFrame
    }

    /// 取得父視窗對應的螢幕可見區（測試實例有指定覆寫可見區時優先採用）。
    static func visibleFrame(for window: NSWindow, override: CGRect? = nil) -> CGRect {
        if let override, override.width > 0, override.height > 0 {
            return override
        }
        return resolveVisibleFrame(
            windowScreenFrame: window.screen?.visibleFrame,
            mainScreenFrame: NSScreen.main?.visibleFrame,
            firstScreenFrame: NSScreen.screens.first?.visibleFrame,
            parentFrame: window.frame
        )
    }

    /// 純函式計算面板幾何（不碰 `NSWindow`／`NSScreen`）：
    /// 1. 可用寬＝螢幕可見區寬 − 24。
    /// 2. 先以 `uiScale` 判斷 4 欄是否放得下；放不下但縮到 `panelScale >= 1.0` 放得下 4 欄時，改用 `panelScale = 可用寬 / 1288` 維持 4 欄；
    ///    縮到 1.0 仍放不下才減欄，減欄時 `panelScale = uiScale`。
    /// 3. 以父視窗置中，水平與垂直皆 clamp 進 `visibleFrame`。
    static func layout(
        parentFrame: CGRect,
        visibleFrame: CGRect,
        uiScale: CGFloat,
        panelHeight: CGFloat = 0
    ) -> Layout {
        let safeScale: CGFloat = (uiScale.isFinite && uiScale > 0) ? uiScale : CGFloat(UIScale.defaultFactor)
        let available = max(0, visibleFrame.width - screenHorizontalMargin)
        let fourColBase = panelWidth(columns: 4, scale: 1) // (300*4 + 12*3 + 18*2) + 16 = 1288
        let fourColAtUI = panelWidth(columns: 4, scale: safeScale)

        let columns: Int
        let panelScale: CGFloat
        let width: CGFloat

        if fourColAtUI <= available {
            columns = 4
            panelScale = safeScale
            width = fourColAtUI
        } else {
            let shrunkScale = fourColBase > 0 ? available / fourColBase : 0
            if shrunkScale >= minShrunkScale, shrunkScale < safeScale {
                columns = 4
                panelScale = shrunkScale
                width = available
            } else {
                var cols = 3
                while cols > 1 && panelWidth(columns: cols, scale: safeScale) > available {
                    cols -= 1
                }
                columns = cols
                panelScale = safeScale
                width = panelWidth(columns: cols, scale: safeScale)
            }
        }

        let rawX = parentFrame.midX - width / 2
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - width)
        let originX = min(max(rawX, visibleFrame.minX), maxX)

        let effectiveHeight = (panelHeight.isFinite && panelHeight > 0) ? panelHeight : 0
        let rawY = parentFrame.midY - effectiveHeight / 2
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - effectiveHeight)
        let originY = min(max(rawY, visibleFrame.minY), maxY)

        return Layout(
            columns: columns,
            panelScale: panelScale,
            panelWidth: width,
            originX: originX,
            originY: originY
        )
    }
}
