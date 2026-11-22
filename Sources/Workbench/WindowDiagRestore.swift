import AppKit
import QuartzCore

// 視窗明確異常值當場復原（只在量到四項可復原異常時動手，正常狀態不動任何屬性）
@MainActor
enum WindowDiagRestore {
    struct Outcome: Equatable {
        var restored: [String]
        var skippedReason: String?
        var beforeLine: String
        var afterLine: String
    }

    @MainActor
    private final class WindowState {
        weak var window: NSWindow?
        var isScheduled = false
        var restoreTimestamps: [TimeInterval] = []

        init(window: NSWindow) {
            self.window = window
        }
    }

    private struct MeasuredValues: Sendable {
        let alpha: Double
        let contentLayerOpacity: Float?
        let bgAlpha: Double?
        let contentViewAlpha: Double?
    }

    private enum ValueStability {
        case notRecoverable
        case stableRecoverable
        case unstableRecoverable
    }

    private struct RestoreMask {
        let alpha: Bool
        let opacity: Bool
        let bgAlpha: Bool
        let viewAlpha: Bool

        static let all = RestoreMask(alpha: true, opacity: true, bgAlpha: true, viewAlpha: true)
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let checkDelay: TimeInterval = 0.5
    private static let minRecoverableAlpha: Double = 0.05
    private static let maxRecoverableAlpha: Double = 0.999
    private static let stabilityTolerance: Double = 0.01
    private static let maxUnstableRetries = 3
    private static let rateLimitWindow: TimeInterval = 60.0
    private static let maxRestoresPerMinute = 3
    private static let logCategory = "視窗診斷!"

    private static var states: [ObjectIdentifier: WindowState] = [:]

    /// 供 WindowDiag 在量到可復原異常時呼叫：記下排程當下的四個可復原值，0.5 秒後重量；數值穩定在 (0.05,0.999) 才復原，仍在變動時最多再排 3 次（共 2 秒內）。同一視窗同時間只排一個檢查。
    static func scheduleCheck(window: NSWindow, trigger: String) {
        let state = windowState(for: window)
        guard !state.isScheduled else { return }
        state.isScheduled = true

        let baseline = measure(window)
        scheduleFollowUpCheck(
            window: window,
            state: state,
            trigger: trigger,
            baseline: baseline,
            remainingRetries: maxUnstableRetries
        )
    }

    /// 同步版（測試探針依賴）：立即量測並復原，不等 0.5 秒。
    static func evaluateAndRestore(_ w: NSWindow, trigger: String) -> Outcome {
        evaluateAndRestore(w, trigger: trigger, mask: .all)
    }

    // MARK: 排程與復原核心

    private static func scheduleFollowUpCheck(
        window: NSWindow,
        state: WindowState,
        trigger: String,
        baseline: MeasuredValues,
        remainingRetries: Int
    ) {
        let key = ObjectIdentifier(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) { [weak window, weak state] in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else {
                    pruneDeadStates()
                    return
                }
                guard let window else {
                    state.isScheduled = false
                    if states[key] === state {
                        states.removeValue(forKey: key)
                    }
                    pruneDeadStates()
                    return
                }
                pruneDeadStates()

                if window.isMiniaturized || !window.isVisible {
                    state.isScheduled = false
                    return
                }

                let current = measure(window)
                let alphaStatus = stabilityStatus(prev: baseline.alpha, curr: current.alpha)
                let opacityStatus = stabilityStatus(prev: baseline.contentLayerOpacity, curr: current.contentLayerOpacity)
                let bgStatus = stabilityStatus(prev: baseline.bgAlpha, curr: current.bgAlpha)
                let viewAlphaStatus = stabilityStatus(prev: baseline.contentViewAlpha, curr: current.contentViewAlpha)

                let stableMask = RestoreMask(
                    alpha: alphaStatus == .stableRecoverable,
                    opacity: opacityStatus == .stableRecoverable,
                    bgAlpha: bgStatus == .stableRecoverable,
                    viewAlpha: viewAlphaStatus == .stableRecoverable
                )
                let hasStable = stableMask.alpha || stableMask.opacity || stableMask.bgAlpha || stableMask.viewAlpha
                let hasUnstable = alphaStatus == .unstableRecoverable
                    || opacityStatus == .unstableRecoverable
                    || bgStatus == .unstableRecoverable
                    || viewAlphaStatus == .unstableRecoverable

                if hasStable {
                    let outcome = evaluateAndRestore(window, trigger: trigger, mask: stableMask)
                    if outcome.skippedReason == "頻率上限" {
                        state.isScheduled = false
                        return
                    }
                }

                if hasUnstable {
                    if remainingRetries > 0 {
                        let nextBaseline = hasStable ? measure(window) : current
                        scheduleFollowUpCheck(
                            window: window,
                            state: state,
                            trigger: trigger,
                            baseline: nextBaseline,
                            remainingRetries: remainingRetries - 1
                        )
                        return
                    }
                    EventLog.log(logCategory, "復原略過 | 原因=數值仍在變動")
                }

                state.isScheduled = false
            }
        }
    }

    private static func evaluateAndRestore(_ w: NSWindow, trigger: String, mask: RestoreMask) -> Outcome {
        if w.isMiniaturized {
            return Outcome(restored: [], skippedReason: "視窗已最小化", beforeLine: "", afterLine: "")
        }
        if !w.isVisible {
            return Outcome(restored: [], skippedReason: "視窗不可見", beforeLine: "", afterLine: "")
        }

        let alphaBefore = Double(w.alphaValue)
        let needRestoreAlpha = mask.alpha && isRecoverable(alphaBefore)

        // 只讀既有 layer，不觸發 wantsLayer
        let contentView = w.contentView
        let contentLayer = contentView?.layer
        let opacityBefore = contentLayer?.opacity
        let needRestoreOpacity = mask.opacity && (opacityBefore.map { isRecoverable($0) } ?? false)

        let bgAlphaBefore = srgbAlpha(of: w.backgroundColor, appearance: w.effectiveAppearance)
        let needRestoreBg = mask.bgAlpha && (bgAlphaBefore.map { isRecoverable($0) } ?? false)

        let viewAlphaBefore = contentView.map { Double($0.alphaValue) }
        let needRestoreViewAlpha = mask.viewAlpha && (viewAlphaBefore.map { isRecoverable($0) } ?? false)

        var pendingItems: [String] = []
        if needRestoreAlpha { pendingItems.append("alpha") }
        if needRestoreOpacity { pendingItems.append("內容層opacity") }
        if needRestoreBg { pendingItems.append("背景alpha") }
        if needRestoreViewAlpha { pendingItems.append("內容viewalpha") }

        if pendingItems.isEmpty {
            return Outcome(restored: [], skippedReason: "無可復原異常", beforeLine: "", afterLine: "")
        }

        let state = windowState(for: w)
        let now = ProcessInfo.processInfo.systemUptime
        state.restoreTimestamps.removeAll { now - $0 >= rateLimitWindow }
        if state.restoreTimestamps.count >= maxRestoresPerMinute {
            EventLog.log(
                logCategory,
                "復原略過 | 觸發=\(trigger) | 原因=頻率上限 | 項目=\(pendingItems.joined(separator: ","))"
            )
            return Outcome(restored: [], skippedReason: "頻率上限", beforeLine: "", afterLine: "")
        }

        let beforeLine = WindowDiag.snapshotLine(w, event: "復原前").line

        // 只改量到異常的那幾項，不動其他視窗屬性
        if needRestoreAlpha {
            w.alphaValue = 1.0
        }
        if needRestoreOpacity, let layer = contentLayer {
            layer.opacity = 1.0
        }
        if needRestoreBg {
            w.backgroundColor = NSColor.windowBackgroundColor
        }
        if needRestoreViewAlpha, let contentView {
            contentView.alphaValue = 1.0
        }

        var restored: [String] = []
        var beforeValues: [String] = []
        var afterValues: [String] = []

        if needRestoreAlpha {
            restored.append("alpha")
            beforeValues.append(fmt3(alphaBefore))
            afterValues.append(fmt3(Double(w.alphaValue)))
        }
        if needRestoreOpacity, let layer = contentLayer, let beforeOpacity = opacityBefore {
            restored.append("內容層opacity")
            beforeValues.append(fmt3(Double(beforeOpacity)))
            let afterOpacity = Double(w.contentView?.layer?.opacity ?? layer.opacity)
            afterValues.append(fmt3(afterOpacity))
        }
        if needRestoreBg, let beforeBg = bgAlphaBefore {
            restored.append("背景alpha")
            beforeValues.append(fmt3(beforeBg))
            let afterBg = srgbAlpha(of: w.backgroundColor, appearance: w.effectiveAppearance)
            afterValues.append(afterBg.map(fmt3) ?? "無")
        }
        if needRestoreViewAlpha, let contentView, let beforeViewAlpha = viewAlphaBefore {
            restored.append("內容viewalpha")
            beforeValues.append(fmt3(beforeViewAlpha))
            let afterViewAlpha = Double(w.contentView?.alphaValue ?? contentView.alphaValue)
            afterValues.append(fmt3(afterViewAlpha))
        }

        state.restoreTimestamps.append(now)

        let itemsText = restored.joined(separator: ",")
        let beforeText = beforeValues.joined(separator: ",")
        let afterText = afterValues.joined(separator: ",")
        EventLog.log(
            logCategory,
            "復原 | 觸發=\(trigger) | 項目=\(itemsText) | 前=\(beforeText) | 後=\(afterText)"
        )

        let afterSnap = WindowDiag.snapshotLine(w, event: "復原後")
        EventLog.log(logCategory, afterSnap.line)

        return Outcome(restored: restored, skippedReason: nil, beforeLine: beforeLine, afterLine: afterSnap.line)
    }

    // MARK: 狀態與數值輔助

    private static func measure(_ w: NSWindow) -> MeasuredValues {
        let contentView = w.contentView
        return MeasuredValues(
            alpha: Double(w.alphaValue),
            contentLayerOpacity: contentView?.layer?.opacity,
            bgAlpha: srgbAlpha(of: w.backgroundColor, appearance: w.effectiveAppearance),
            contentViewAlpha: contentView.map { Double($0.alphaValue) }
        )
    }

    private static func stabilityStatus(prev: Double?, curr: Double?) -> ValueStability {
        guard let curr, isRecoverable(curr) else { return .notRecoverable }
        guard let prev, isRecoverable(prev), abs(curr - prev) < stabilityTolerance else {
            return .unstableRecoverable
        }
        return .stableRecoverable
    }

    private static func stabilityStatus(prev: Float?, curr: Float?) -> ValueStability {
        guard let curr, isRecoverable(curr) else { return .notRecoverable }
        guard let prev, isRecoverable(prev), abs(Double(curr) - Double(prev)) < stabilityTolerance else {
            return .unstableRecoverable
        }
        return .stableRecoverable
    }

    private static func windowState(for window: NSWindow) -> WindowState {
        pruneDeadStates()
        let key = ObjectIdentifier(window)
        if let existing = states[key], existing.window === window {
            return existing
        }
        let created = WindowState(window: window)
        states[key] = created
        return created
    }

    private static func pruneDeadStates() {
        states = states.filter { $0.value.window != nil }
    }

    private static func isRecoverable(_ value: Double) -> Bool {
        value > minRecoverableAlpha && value < maxRecoverableAlpha
    }

    private static func isRecoverable(_ value: Float) -> Bool {
        value > Float(minRecoverableAlpha) && value < Float(maxRecoverableAlpha)
    }

    private static func fmt3(_ value: Double) -> String {
        String(format: "%.3f", locale: posixLocale, value)
    }

    private static func srgbAlpha(of color: NSColor?, appearance: NSAppearance) -> Double? {
        guard let color else { return nil }
        var converted: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            converted = color.usingColorSpace(.sRGB)
        }
        guard let c = converted else { return nil }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(a)
    }
}
