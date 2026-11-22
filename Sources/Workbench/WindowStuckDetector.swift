import AppKit
import CoreGraphics
import Foundation

// 視窗「消失／非作用中 Space」純邏輯偵測器與快照組裝器（不碰真視窗、不讀真系統狀態、不寫磁碟）

/// 偵測器單次取樣輸入（可由實機收集或單元測試／--window-diag-inject 注入）
struct WindowStuckSample: Equatable, Sendable {
    var isActive: Bool
    var isKey: Bool
    var isMain: Bool
    var occVisible: Bool
    /// WindowServer kCGWindowIsOnscreen：true＝在畫面上、false＝明確 false、nil＝查不到視窗或未帶此鍵
    var wsOnscreen: Bool?

    init(
        isActive: Bool,
        isKey: Bool,
        isMain: Bool = false,
        occVisible: Bool,
        wsOnscreen: Bool? = true
    ) {
        self.isActive = isActive
        self.isKey = isKey
        self.isMain = isMain
        self.occVisible = occVisible
        self.wsOnscreen = wsOnscreen
    }

    /// 條件 A：NSApp.isActive 且主視窗 isKeyWindow，但 occlusionState 不含 .visible
    var matchesConditionA: Bool {
        isActive && isKey && !occVisible
    }

    /// 條件 B：主視窗 isKeyWindow 或 isMainWindow 為 true，但 WindowServer onscreen 不是 true（false 或查不到皆算）
    var matchesConditionB: Bool {
        (isKey || isMain) && wsOnscreen != true
    }

    var triggerReason: WindowStuckTrigger? {
        switch (matchesConditionA, matchesConditionB) {
        case (true, true): return .both
        case (true, false): return .conditionA
        case (false, true): return .conditionB
        case (false, false): return nil
        }
    }

    var isStuck: Bool {
        matchesConditionA || matchesConditionB
    }
}

enum WindowStuckTrigger: String, Equatable, Sendable {
    case conditionA = "A(active+key+occ_hidden)"
    case conditionB = "B(key_or_main+ws_not_onscreen)"
    case both = "A+B"
}

enum WindowStuckDecision: Equatable, Sendable {
    /// 條件未成立，不需計時
    case idle
    /// 條件成立但尚未滿持續門檻（1.5 秒）
    case pending(remaining: TimeInterval)
    /// 達觸發條件，應寫出第 sequence 份快照
    case emit(trigger: WindowStuckTrigger, sequence: Int)
    /// 同一次事件已寫過，直到條件解除前不再重複寫
    case suppressedSameIncident
    /// 條件曾解除後再次成立，但仍在 60 秒冷卻窗內
    case suppressedCooldown(remaining: TimeInterval)
    /// 本次啟動已達總快照份數上限
    case suppressedSessionLimit

    var shouldEmit: Bool {
        if case .emit = self { return true }
        return false
    }
}

/// 純狀態機：判斷是否該寫出「視窗快照」（時鐘可注入，便於單元測試）
struct WindowStuckDetector {
    static let defaultDwellDuration: TimeInterval = 1.5
    static let defaultCooldownDuration: TimeInterval = 60.0
    static let defaultMaxSnapshotsPerLaunch = 20

    let dwellDuration: TimeInterval
    let cooldownDuration: TimeInterval
    let maxSnapshotsPerLaunch: Int
    private let clock: @Sendable () -> TimeInterval

    private(set) var stuckSince: TimeInterval?
    private(set) var emittedInCurrentIncident = false
    private(set) var lastEmitTime: TimeInterval?
    private(set) var emittedCount = 0

    init(
        dwellDuration: TimeInterval = WindowStuckDetector.defaultDwellDuration,
        cooldownDuration: TimeInterval = WindowStuckDetector.defaultCooldownDuration,
        maxSnapshotsPerLaunch: Int = WindowStuckDetector.defaultMaxSnapshotsPerLaunch,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.dwellDuration = dwellDuration
        self.cooldownDuration = cooldownDuration
        self.maxSnapshotsPerLaunch = maxSnapshotsPerLaunch
        self.clock = clock
    }

    /// 使用注入時鐘評估目前取樣
    mutating func evaluate(_ sample: WindowStuckSample) -> WindowStuckDecision {
        evaluate(sample, at: clock())
    }

    /// 以明確時間戳評估取樣
    mutating func evaluate(_ sample: WindowStuckSample, at now: TimeInterval) -> WindowStuckDecision {
        guard let trigger = sample.triggerReason else {
            stuckSince = nil
            emittedInCurrentIncident = false
            return .idle
        }

        if emittedInCurrentIncident {
            return .suppressedSameIncident
        }
        if emittedCount >= maxSnapshotsPerLaunch {
            return .suppressedSessionLimit
        }

        if let start = stuckSince {
            if now < start {
                stuckSince = now
            }
        } else {
            stuckSince = now
        }

        let eps: TimeInterval = 1e-9
        let elapsed = now - (stuckSince ?? now)
        if elapsed + eps < dwellDuration {
            return .pending(remaining: max(0, dwellDuration - elapsed))
        }

        if let lastEmit = lastEmitTime {
            let sinceLast = now - lastEmit
            if sinceLast + eps < cooldownDuration {
                return .suppressedCooldown(remaining: max(0, cooldownDuration - sinceLast))
            }
        }

        emittedCount += 1
        emittedInCurrentIncident = true
        lastEmitTime = now
        return .emit(trigger: trigger, sequence: emittedCount)
    }

    mutating func reset() {
        stuckSince = nil
        emittedInCurrentIncident = false
        lastEmitTime = nil
        emittedCount = 0
    }
}

// MARK: - 測試注入規格（只在 --state-dir 測試實例生效）

enum WindowRescueInjectOutcome: String, Equatable, Sendable {
    case step1 = "1"
    case step2 = "2"
    case step3 = "3"
    case never = "none"
}

struct AlphaScanInjectedNode: Equatable, Sendable {
    var path: String
    var opacity: Double
}

struct WindowDiagOverride: Equatable, Sendable {
    var isActive: Bool?
    var isKey: Bool?
    var isMain: Bool?
    var occVisible: Bool?
    var isOnActiveSpace: Bool?
    /// nil＝不覆寫；.some(nil)＝覆寫為查不到／無；.some(true/false)＝覆寫為 true/false
    var wsOnscreen: Bool??
    /// 第 2 輪：`frameout=1` 假裝 frame 在所有有效螢幕聯集外（frameInUnion = false）
    var frameOutOfBounds: Bool?
    /// 第 2 輪：`rescue-ok=<1|2|3|none>` 假裝點 Dock 救援第幾步救得回
    var rescueOutcome: WindowRescueInjectOutcome?
    /// 第 2 輪：`alpha-node=<路徑>:<opacity>` 假裝掃描到半透明節點
    var alphaNodes: [AlphaScanInjectedNode]?

    var hasAnyOverride: Bool {
        isActive != nil || isKey != nil || isMain != nil
            || occVisible != nil || isOnActiveSpace != nil || wsOnscreen != nil
            || frameOutOfBounds != nil || rescueOutcome != nil
            || (alphaNodes.map { !$0.isEmpty } ?? false)
    }

    mutating func merge(_ patch: WindowDiagOverride) {
        if let v = patch.isActive { isActive = v }
        if let v = patch.isKey { isKey = v }
        if let v = patch.isMain { isMain = v }
        if let v = patch.occVisible { occVisible = v }
        if let v = patch.isOnActiveSpace { isOnActiveSpace = v }
        if let v = patch.wsOnscreen { wsOnscreen = v }
        if let v = patch.frameOutOfBounds { frameOutOfBounds = v }
        if let v = patch.rescueOutcome { rescueOutcome = v }
        if let v = patch.alphaNodes { alphaNodes = v }
    }

    func applying(to live: WindowStuckSample) -> WindowStuckSample {
        WindowStuckSample(
            isActive: isActive ?? live.isActive,
            isKey: isKey ?? live.isKey,
            isMain: isMain ?? live.isMain,
            occVisible: occVisible ?? live.occVisible,
            wsOnscreen: wsOnscreen ?? live.wsOnscreen
        )
    }
}

struct WindowDiagInjectCommand: Equatable, Sendable {
    var delaySeconds: TimeInterval
    var clear: Bool
    var patch: WindowDiagOverride
    var triggerReopen: Bool?

    /// 解析 `--window-diag-inject <spec>`：支援第 1 輪 `occ=hidden,space=off,active=1,key=1,main=1,onscreen=0|1|none`
    /// 與第 2 輪 `frameout=1`、`rescue-ok=1|2|3|none`、`alpha-node=<路徑>:<opacity>`，
    /// 以及選擇性的 `<秒數>:<spec>` 前綴（例如 `3.5:occ=visible` 或 `4.0:clear`）。
    static func parse(_ raw: String) -> WindowDiagInjectCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var delaySeconds: TimeInterval = 0
        var body = trimmed
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            if let sec = Double(prefix), sec.isFinite, sec >= 0 {
                delaySeconds = sec
                body = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !body.isEmpty else { return nil }

        var clear = false
        var patch = WindowDiagOverride()
        var triggerReopen: Bool?
        var parsedAlphaNodes: [AlphaScanInjectedNode] = []
        var recognizedAny = false

        for part in body.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let loweredToken = token.lowercased()
            if loweredToken == "clear" || loweredToken == "reset" {
                clear = true
                recognizedAny = true
                continue
            }
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = token[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(token[token.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let value = rawValue.lowercased()

            switch key {
            case "occ", "occlusion":
                if let v = parseOcc(value) {
                    patch.occVisible = v
                    recognizedAny = true
                }
            case "space", "onactivespace":
                if let v = parseSpace(value) {
                    patch.isOnActiveSpace = v
                    recognizedAny = true
                }
            case "active":
                if let v = parseBool(value) {
                    patch.isActive = v
                    recognizedAny = true
                }
            case "key":
                if let v = parseBool(value) {
                    patch.isKey = v
                    recognizedAny = true
                }
            case "main":
                if let v = parseBool(value) {
                    patch.isMain = v
                    recognizedAny = true
                }
            case "onscreen", "wsonscreen":
                if value == "none" || value == "nil" || value == "na" || value == "n/a" || value == "無" {
                    patch.wsOnscreen = .some(nil)
                    recognizedAny = true
                } else if let v = parseBool(value) {
                    patch.wsOnscreen = .some(v)
                    recognizedAny = true
                }
            case "frameout", "frame-out":
                if let v = parseBool(value) {
                    patch.frameOutOfBounds = v
                    recognizedAny = true
                }
            case "rescue-ok", "rescueok":
                if let outcome = parseRescueOutcome(value) {
                    patch.rescueOutcome = outcome
                    recognizedAny = true
                }
            case "alpha-node", "alphanode":
                if let node = parseAlphaNode(rawValue) {
                    parsedAlphaNodes.append(node)
                    recognizedAny = true
                }
            case "reopen":
                if let v = parseBool(value) {
                    triggerReopen = v
                    recognizedAny = true
                }
            default:
                continue
            }
        }

        if !parsedAlphaNodes.isEmpty {
            patch.alphaNodes = parsedAlphaNodes
        }

        guard recognizedAny else { return nil }
        return WindowDiagInjectCommand(
            delaySeconds: delaySeconds,
            clear: clear,
            patch: patch,
            triggerReopen: triggerReopen
        )
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func parseOcc(_ s: String) -> Bool? {
        switch s {
        case "visible", "1", "true": return true
        case "hidden", "0", "false": return false
        default: return nil
        }
    }

    private static func parseSpace(_ s: String) -> Bool? {
        switch s {
        case "on", "active", "1", "true": return true
        case "off", "inactive", "0", "false": return false
        default: return nil
        }
    }

    private static func parseRescueOutcome(_ s: String) -> WindowRescueInjectOutcome? {
        switch s {
        case "1", "step1": return .step1
        case "2", "step2": return .step2
        case "3", "step3": return .step3
        case "none", "0", "fail", "false": return .never
        default: return nil
        }
    }

    private static func parseAlphaNode(_ raw: String) -> AlphaScanInjectedNode? {
        guard let colon = raw.lastIndex(of: ":") else { return nil }
        let path = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
        let opText = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let opacity = Double(opText), opacity.isFinite, opacity >= 0, opacity <= 1 else {
            return nil
        }
        return AlphaScanInjectedNode(path: path, opacity: opacity)
    }
}

// MARK: - 快照純資料結構與格式化（不含視窗標題或螢幕名稱，避免洩漏使用者資料）

struct WindowSnapshotRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Self.safeRoundedInt(rect.origin.x)
        self.y = Self.safeRoundedInt(rect.origin.y)
        self.width = Self.safeRoundedInt(rect.size.width)
        self.height = Self.safeRoundedInt(rect.size.height)
    }

    private static func safeRoundedInt(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        let clamped = max(CGFloat(Int32.min), min(CGFloat(Int32.max), value.rounded()))
        return Int(clamped)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var formatted: String {
        "(\(x),\(y) \(width)×\(height))"
    }

    func intersectsPositiveArea(_ other: WindowSnapshotRect) -> Bool {
        let inter = cgRect.intersection(other.cgRect)
        return !inter.isNull && inter.width > 0 && inter.height > 0
    }
}

struct WindowSnapshotScreen: Equatable, Sendable {
    var index: Int
    var kind: String
    var isPrimary: Bool
    var isMain: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double
    var frame: WindowSnapshotRect
    var visibleFrame: WindowSnapshotRect

    /// 間接全螢幕／無選單列訊號：上緣沒有預留選單列高度
    var hasNoMenuBarTopInset: Bool {
        let topInset = (frame.y + frame.height) - (visibleFrame.y + visibleFrame.height)
        return topInset < 1
    }
}

struct WindowSnapshotOwnWindow: Equatable, Sendable {
    var index: Int
    var isPrimaryMainWindow: Bool
    var frame: WindowSnapshotRect
    var isOnActiveSpace: Bool
    var isVisible: Bool
    var occVisible: Bool
    var isKey: Bool
    var isMain: Bool
    var isMiniaturized: Bool
    var screenLabel: String
    var level: Int
    var wsOnscreen: Bool?
    var space: String
    var collectionBehaviorRaw: UInt
    /// 第 2 輪 A.2 追加欄位（附預設值以維持第 1 輪呼叫與單測相容）
    var alpha: Double
    var windowNumber: Int?
    var windowClass: String?

    init(
        index: Int,
        isPrimaryMainWindow: Bool,
        frame: WindowSnapshotRect,
        isOnActiveSpace: Bool,
        isVisible: Bool,
        occVisible: Bool,
        isKey: Bool,
        isMain: Bool,
        isMiniaturized: Bool,
        screenLabel: String,
        level: Int,
        wsOnscreen: Bool?,
        space: String,
        collectionBehaviorRaw: UInt,
        alpha: Double = 1.0,
        windowNumber: Int? = nil,
        windowClass: String? = nil
    ) {
        self.index = index
        self.isPrimaryMainWindow = isPrimaryMainWindow
        self.frame = frame
        self.isOnActiveSpace = isOnActiveSpace
        self.isVisible = isVisible
        self.occVisible = occVisible
        self.isKey = isKey
        self.isMain = isMain
        self.isMiniaturized = isMiniaturized
        self.screenLabel = screenLabel
        self.level = level
        self.wsOnscreen = wsOnscreen
        self.space = space
        self.collectionBehaviorRaw = collectionBehaviorRaw
        self.alpha = alpha
        self.windowNumber = windowNumber
        self.windowClass = windowClass
    }
}

struct WindowSnapshotExternalWindow: Equatable, Sendable {
    var windowNumber: UInt32
    var ownerPID: Int32
    /// 只存 kCGWindowOwnerName，絕不讀也不存 kCGWindowName
    var ownerName: String
    var layer: Int
    /// AppKit 座標系（原點為主螢幕左下角、Y 向上），便於與 NSWindow.frame／NSScreen.frame 直接對照
    var bounds: WindowSnapshotRect
    var alpha: Double
    var isOnscreen: Bool?
}

struct WindowSnapshotEnvironment: Equatable, Sendable {
    var screensHaveSeparateSpaces: Bool
    var presentationOptionsRaw: UInt
    var menuBarVisible: Bool
    var frontmostAppName: String?
    var frontmostActivationPolicy: String
    var frontmostIsSelf: Bool?
}

struct WindowSnapshotData: Equatable, Sendable {
    var sequence: Int
    var trigger: WindowStuckTrigger
    var source: String
    var sample: WindowStuckSample
    var mainOnActiveSpace: Bool?
    var screens: [WindowSnapshotScreen]
    var ownWindows: [WindowSnapshotOwnWindow]
    var environment: WindowSnapshotEnvironment
    var fullscreenLayer0Matches: [String]
    var aboveWindows: [WindowSnapshotExternalWindow]
}

struct DockReopenSnapshot: Equatable, Sendable {
    var hasWindow: Bool
    var isOnActiveSpace: Bool?
    var occVisible: Bool?
    var isVisible: Bool?
    var isKeyWindow: Bool?
    var isMiniaturized: Bool?
    var isAppActive: Bool
    var hasVisibleWindows: Bool
}

enum WindowSnapshotFormatter {
    static let snapshotCategory = "視窗快照"
    static let diagnosticCategory = "視窗診斷"
    static let maxOwnWindows = 40
    static let maxAboveWindows = 20
    static let maxFullscreenMatches = 4

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// 將 CoreGraphics 座標（原點為主螢幕左上角、Y 向下）轉為 AppKit 座標（原點為主螢幕左下角、Y 向上）
    static func convertCGToAppKitRect(_ cgRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgRect.origin.x,
            y: primaryScreenHeight - (cgRect.origin.y + cgRect.size.height),
            width: cgRect.size.width,
            height: cgRect.size.height
        )
    }

    /// 公開 API：只查 CGWindowList 字典中的 "kCGWindowWorkspace"（macOS 10.8 起系統已標記不支援，實機若拿不到回 "n/a"）
    static func extractWorkspaceID(from windowInfo: [String: Any]?) -> String {
        if let num = windowInfo?["kCGWindowWorkspace"] as? NSNumber {
            return "\(num.intValue)"
        }
        if let str = windowInfo?["kCGWindowWorkspace"] as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "n/a"
    }

    /// 追加在 WindowDiag 每筆事件末尾的新欄位（不更動既有欄位名稱與順序）
    static func formatWindowDiagSpaceSuffix(onActiveSpace: Bool, space: String) -> String {
        let spaceValue = space.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSpace = spaceValue.isEmpty ? "n/a" : spaceValue
        return " | onActiveSpace=\(onActiveSpace) space=\(finalSpace)"
    }

    /// 格式化 `applicationShouldHandleReopen`（點 Dock）診斷行
    static func formatDockReopenLine(_ state: DockReopenSnapshot) -> String {
        let prefix = "事件=點Dock重開 | appActive=\(state.isAppActive) hasVisibleWindows=\(state.hasVisibleWindows)"
        guard state.hasWindow else {
            return "\(prefix) | 主視窗=無"
        }
        return "\(prefix) | 主視窗 onActiveSpace=\(fmtOptBool(state.isOnActiveSpace)) occ=\(fmtOptOcc(state.occVisible)) visible=\(fmtOptBool(state.isVisible)) key=\(fmtOptBool(state.isKeyWindow)) miniaturized=\(fmtOptBool(state.isMiniaturized))"
    }

    /// 篩選同一螢幕上疊在我們視窗之上的其他程式視窗（按 front-to-back 順序，最多 limit 筆）
    static func filterAboveWindows(
        allOnscreenFrontToBack: [WindowSnapshotExternalWindow],
        ourWindowNumber: UInt32?,
        ourPID: Int32,
        ourFrame: WindowSnapshotRect,
        ourScreenFrame: WindowSnapshotRect?,
        limit: Int = maxAboveWindows
    ) -> [WindowSnapshotExternalWindow] {
        guard limit > 0, ourFrame.width > 0, ourFrame.height > 0 else { return [] }
        var result: [WindowSnapshotExternalWindow] = []
        for entry in allOnscreenFrontToBack {
            if let targetID = ourWindowNumber, entry.windowNumber == targetID {
                break
            }
            if entry.ownerPID == ourPID {
                continue
            }
            guard entry.bounds.intersectsPositiveArea(ourFrame) else {
                continue
            }
            if let screenFrame = ourScreenFrame, !entry.bounds.intersectsPositiveArea(screenFrame) {
                continue
            }
            result.append(entry)
            if result.count >= limit {
                break
            }
        }
        return result
    }

    /// 偵測其他程式在任一螢幕上的 layer == 0 且 bounds 覆蓋整台螢幕 frame 的視窗（全螢幕間接訊號）
    static func detectFullscreenLayer0Windows(
        onscreenWindows: [WindowSnapshotExternalWindow],
        screens: [WindowSnapshotScreen],
        ourPID: Int32,
        tolerance: Int = 2,
        limit: Int = maxFullscreenMatches
    ) -> [String] {
        guard limit > 0, !screens.isEmpty else { return [] }
        var matches: [String] = []
        var seen: Set<String> = []
        for entry in onscreenWindows {
            guard entry.ownerPID != ourPID,
                  entry.layer == 0,
                  entry.alpha > 0.001,
                  entry.isOnscreen == true else { continue }
            for screen in screens {
                let b = entry.bounds
                let f = screen.frame
                if abs(b.x - f.x) <= tolerance
                    && abs(b.y - f.y) <= tolerance
                    && abs(b.width - f.width) <= tolerance
                    && abs(b.height - f.height) <= tolerance {
                    let owner = sanitizeOwner(entry.ownerName, maxLen: 20)
                    let label = "\(owner)@螢幕\(screen.index)"
                    if seen.insert(label).inserted {
                        matches.append(label)
                        if matches.count >= limit {
                            return matches
                        }
                    }
                    break
                }
            }
        }
        return matches
    }

    /// 格式化 NSWindow.CollectionBehavior 關鍵位
    static func formatCollectionBehavior(rawValue: UInt) -> String {
        let b = NSWindow.CollectionBehavior(rawValue: rawValue)
        var names: [String] = []
        if b.contains(.canJoinAllSpaces) { names.append("canJoinAllSpaces") }
        if b.contains(.moveToActiveSpace) { names.append("moveToActiveSpace") }
        if b.contains(.managed) { names.append("managed") }
        if b.contains(.transient) { names.append("transient") }
        if b.contains(.stationary) { names.append("stationary") }
        if b.contains(.participatesInCycle) { names.append("participatesInCycle") }
        if b.contains(.ignoresCycle) { names.append("ignoresCycle") }
        if b.contains(.fullScreenPrimary) { names.append("fullScreenPrimary") }
        if b.contains(.fullScreenAuxiliary) { names.append("fullScreenAuxiliary") }
        if b.contains(.fullScreenNone) { names.append("fullScreenNone") }
        if b.contains(.fullScreenAllowsTiling) { names.append("fullScreenAllowsTiling") }
        if b.contains(.fullScreenDisallowsTiling) { names.append("fullScreenDisallowsTiling") }
        if b.contains(.primary) { names.append("primary") }
        if b.contains(.auxiliary) { names.append("auxiliary") }
        if b.contains(.canJoinAllApplications) { names.append("canJoinAllApplications") }
        let hex = String(format: "0x%x", rawValue)
        let body = names.isEmpty ? "default" : names.joined(separator: ",")
        return "\(body)(\(hex))"
    }

    /// 格式化 NSApplication.PresentationOptions 關鍵位
    static func formatPresentationOptions(rawValue: UInt) -> String {
        let opts = NSApplication.PresentationOptions(rawValue: rawValue)
        var names: [String] = []
        if opts.contains(.autoHideDock) { names.append("autoHideDock") }
        if opts.contains(.hideDock) { names.append("hideDock") }
        if opts.contains(.autoHideMenuBar) { names.append("autoHideMenuBar") }
        if opts.contains(.hideMenuBar) { names.append("hideMenuBar") }
        if opts.contains(.fullScreen) { names.append("fullScreen") }
        if opts.contains(.autoHideToolbar) { names.append("autoHideToolbar") }
        let hex = String(format: "0x%x", rawValue)
        let body = names.isEmpty ? "default" : names.joined(separator: ",")
        return "\(body)(\(hex))"
    }

    static func formatActivationPolicy(_ policy: NSApplication.ActivationPolicy?) -> String {
        guard let policy else { return "n/a" }
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown(\(policy.rawValue))"
        }
    }

    /// 組裝「視窗快照」多行輸出（每行皆控制於 EventLog 400 字上限內，具明確開始／結束標記）
    static func formatLines(_ data: WindowSnapshotData) -> [String] {
        let seq = data.sequence
        let prefix = "快照#\(seq)"
        var lines: [String] = []

        // 1. 起始標記行
        let occText = data.sample.occVisible ? "visible" : "hidden"
        let wsText = fmtWsOnscreen(data.sample.wsOnscreen)
        let spaceText = fmtOptBool(data.mainOnActiveSpace)
        let cappedOwn = Array(data.ownWindows.prefix(maxOwnWindows))
        let cappedAbove = Array(data.aboveWindows.prefix(maxAboveWindows))
        lines.append(
            "\(prefix) 開始 | 觸發=\(data.trigger.rawValue) 來源=\(data.source) | active=\(data.sample.isActive) key=\(data.sample.isKey) main=\(data.sample.isMain) occ=\(occText) wsOnscreen=\(wsText) onActiveSpace=\(spaceText) | 螢幕數=\(data.screens.count) 視窗數=\(cappedOwn.count) 上層視窗數=\(cappedAbove.count)"
        )

        // 2. 所有螢幕
        if data.screens.isEmpty {
            lines.append("\(prefix) 螢幕 | 無")
        } else {
            for s in data.screens {
                let scaleText = String(format: "%.1f", locale: posixLocale, s.scale)
                lines.append(
                    "\(prefix) 螢幕#\(s.index) | 種類=\(s.kind) primary=\(s.isPrimary) main=\(s.isMain) px=\(s.pixelWidth)×\(s.pixelHeight) scale=\(scaleText) frame=\(s.frame.formatted) visible=\(s.visibleFrame.formatted)"
                )
            }
        }

        // 3. 我們每個視窗（第 2 輪 A.2：含全部 NSApp.windows 最多 40 筆，不記視窗標題）
        if cappedOwn.isEmpty {
            lines.append("\(prefix) 視窗 | 無")
        } else {
            for w in cappedOwn {
                let role = w.isPrimaryMainWindow ? "主視窗" : "其他視窗"
                let wOcc = w.occVisible ? "visible" : "hidden"
                let behavior = formatCollectionBehavior(rawValue: w.collectionBehaviorRaw)
                let alphaText = String(format: "%.3f", locale: posixLocale, w.alpha)
                let wnText = w.windowNumber.map { "\($0)" } ?? "n/a"
                let clsText = w.windowClass.map { WindowDiagFieldsFormatter.sanitizedClassName($0) } ?? "NSWindow"
                lines.append(
                    "\(prefix) 視窗#\(w.index) | role=\(role) frame=\(w.frame.formatted) onActiveSpace=\(w.isOnActiveSpace) visible=\(w.isVisible) occ=\(wOcc) key=\(w.isKey) main=\(w.isMain) mini=\(w.isMiniaturized) 螢幕=\(w.screenLabel) level=\(w.level) wsOnscreen=\(fmtWsOnscreen(w.wsOnscreen)) space=\(w.space) behavior=\(behavior) alpha=\(alphaText) wn=\(wnText) cls=\(clsText)"
                )
            }
        }

        // 4. 環境與全螢幕訊號
        let env = data.environment
        let presText = formatPresentationOptions(rawValue: env.presentationOptionsRaw)
        let frontAppText = env.frontmostAppName.map { sanitizeOwner($0) } ?? "n/a"
        let frontSelfText = fmtOptBool(env.frontmostIsSelf)
        let noMenuScreens = data.screens.filter(\.hasNoMenuBarTopInset).map { "\($0.index)" }
        let noMenuText = noMenuScreens.isEmpty ? "無" : noMenuScreens.joined(separator: ",")
        let fsMatches = Array(data.fullscreenLayer0Matches.prefix(maxFullscreenMatches))
        let fsText = fsMatches.isEmpty ? "無" : fsMatches.joined(separator: ",")
        let presFullScreen = NSApplication.PresentationOptions(rawValue: env.presentationOptionsRaw).contains(.fullScreen)
        let fsSuspected = !fsMatches.isEmpty || !env.menuBarVisible || presFullScreen
        lines.append(
            "\(prefix) 環境 | separateSpaces=\(env.screensHaveSeparateSpaces) presentation=\(presText) menuBarVisible=\(env.menuBarVisible) frontApp=\(frontAppText) frontPolicy=\(env.frontmostActivationPolicy) frontIsSelf=\(frontSelfText) screensNoMenuBar=\(noMenuText) fullscreenLayer0=\(fsText) fullscreenSuspected=\(fsSuspected)"
        )

        // 5. 同一螢幕疊在我們視窗上面的其他程式視窗（最多 20 筆，不記視窗標題）
        if cappedAbove.isEmpty {
            lines.append("\(prefix) 上層視窗 | 無")
        } else {
            for (idx, w) in cappedAbove.enumerated() {
                let owner = sanitizeOwner(w.ownerName)
                let alphaText = String(format: "%.3f", locale: posixLocale, w.alpha)
                lines.append(
                    "\(prefix) 上層視窗#\(idx + 1) | owner=\(owner) layer=\(w.layer) bounds=\(w.bounds.formatted) alpha=\(alphaText) onscreen=\(fmtWsOnscreen(w.isOnscreen))"
                )
            }
        }

        // 6. 結束標記行
        let totalLines = lines.count + 1
        lines.append("\(prefix) 結束 | 行數=\(totalLines)")
        return lines
    }

    /// 透過可注入的 sink 寫出整份快照（預設寫入 EventLog.log）
    static func emitSnapshot(
        _ data: WindowSnapshotData,
        sink: (String, String) -> Void = { EventLog.log($0, $1) }
    ) {
        for line in formatLines(data) {
            sink(snapshotCategory, line)
        }
    }

    // MARK: 內部格式輔助

    private static func sanitizeOwner(_ raw: String, maxLen: Int = 32) -> String {
        let cleaned = raw
            .replacingOccurrences(of: #"[\r\n\t|]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "未知" }
        return cleaned.count > maxLen ? String(cleaned.prefix(maxLen)) : cleaned
    }

    private static func fmtWsOnscreen(_ v: Bool?) -> String {
        guard let v else { return "none" }
        return v ? "true" : "false"
    }

    private static func fmtOptBool(_ v: Bool?) -> String {
        guard let v else { return "n/a" }
        return v ? "true" : "false"
    }

    private static func fmtOptOcc(_ v: Bool?) -> String {
        guard let v else { return "n/a" }
        return v ? "visible" : "hidden"
    }
}

// MARK: - 第 2 輪 A.1：每筆視窗診斷追加欄位（純邏輯、可單測）

struct WindowDiagScreenInfo: Equatable, Sendable {
    var displayID: UInt32?
    var frame: WindowSnapshotRect
}

struct WindowDiagCGAllInfo: Equatable, Sendable {
    /// CoreGraphics 原始 kCGWindowBounds（左上原點）；解析不到時為 nil
    var bounds: WindowSnapshotRect?
    /// kCGWindowIsOnscreen（true / false / nil 代表鍵缺失）
    var isOnscreen: Bool?
    /// kCGWindowMemoryUsage（位元組；0 代表 backing store 已釋放）
    var memoryUsage: Int64?
}

struct WindowDiagExtendedFields: Equatable, Sendable {
    var frame: WindowSnapshotRect
    var screenID: UInt32?
    var screens: [WindowDiagScreenInfo]
    var activeDisplays: [UInt32]
    var frameInUnion: Bool
    var isVisible: Bool
    var isMiniaturized: Bool
    var appHidden: Bool
    var collectionBehaviorRaw: UInt
    var level: Int
    var parentWindowNumber: Int?
    var childWindowNumbers: [Int]
    var windowNumber: Int
    /// 上一次記錄此視窗診斷時的 windowNumber（nil 表示首筆；與 windowNumber 不同時加 wnChanged=舊->新）
    var previousWindowNumber: Int?
    /// 以 CGWindowListCopyWindowInfo(.optionAll) 查得的本視窗資訊（查不到時為 nil -> cgAll=none）
    var cgAll: WindowDiagCGAllInfo?
}

enum WindowDiagFieldsFormatter {
    /// 判斷 windowFrame 是否與所有有效螢幕 frame 的「集合聯集」有正面積交集（而非外接矩形 bounding box，避免 L 形排列空區誤判）
    /// - Parameter activeDisplayIDs: 傳 nil 表示不過濾 displayID；傳陣列（含空陣列）時只認定 displayID 在 active 清單中的螢幕為有效螢幕
    static func isFrameInUnion(
        frame: WindowSnapshotRect,
        screens: [WindowDiagScreenInfo],
        activeDisplayIDs: [UInt32]? = nil
    ) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let validScreens: [WindowDiagScreenInfo]
        if let active = activeDisplayIDs {
            guard !active.isEmpty else { return false }
            let activeSet = Set(active)
            validScreens = screens.filter { s in
                s.frame.width > 0 && s.frame.height > 0 && (s.displayID.map { activeSet.contains($0) } ?? true)
            }
        } else {
            validScreens = screens.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        }
        return validScreens.contains { frame.intersectsPositiveArea($0.frame) }
    }

    /// 解析 CGWindowListCopyWindowInfo(.optionAll) 單筆視窗字典為 WindowDiagCGAllInfo
    static func parseCGAllInfo(from dict: [String: Any]?) -> WindowDiagCGAllInfo? {
        guard let dict else { return nil }

        var parsedBounds: WindowSnapshotRect?
        if let rawBounds = dict[kCGWindowBounds as String] as? NSDictionary {
            var cgRect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(rawBounds, &cgRect),
               cgRect.origin.x.isFinite, cgRect.origin.y.isFinite,
               cgRect.size.width.isFinite, cgRect.size.height.isFinite {
                parsedBounds = WindowSnapshotRect(cgRect)
            }
        }

        let onscreenKey = kCGWindowIsOnscreen as String
        let isOnscreen: Bool?
        if let b = dict[onscreenKey] as? Bool {
            isOnscreen = b
        } else if let n = dict[onscreenKey] as? NSNumber {
            isOnscreen = n.boolValue
        } else {
            isOnscreen = nil
        }

        let mem: Int64?
        if let n = dict[kCGWindowMemoryUsage as String] as? NSNumber {
            mem = n.int64Value
        } else if let i = dict[kCGWindowMemoryUsage as String] as? Int {
            mem = Int64(i)
        } else if let i64 = dict[kCGWindowMemoryUsage as String] as? Int64 {
            mem = i64
        } else {
            mem = nil
        }

        return WindowDiagCGAllInfo(bounds: parsedBounds, isOnscreen: isOnscreen, memoryUsage: mem)
    }

    static func formatScreens(_ screens: [WindowDiagScreenInfo]) -> String {
        guard !screens.isEmpty else { return "none" }
        return screens.map { s in
            let idText = s.displayID.map { "\($0)" } ?? "n/a"
            return "\(idText)@\(s.frame.x),\(s.frame.y),\(s.frame.width)x\(s.frame.height)"
        }.joined(separator: ";")
    }

    static func formatActiveDisplays(_ ids: [UInt32]) -> String {
        guard !ids.isEmpty else { return "none" }
        return ids.map { "\($0)" }.joined(separator: ",")
    }

    static func formatCGAll(_ info: WindowDiagCGAllInfo?) -> String {
        guard let info else { return "none" }
        let boundsText: String
        if let b = info.bounds {
            boundsText = "bounds(\(b.x),\(b.y),\(b.width)x\(b.height))"
        } else {
            boundsText = "bounds(n/a)"
        }
        let onText: String
        if let on = info.isOnscreen {
            onText = on ? "true" : "false"
        } else {
            onText = "none"
        }
        let memText = info.memoryUsage.map { "\($0)" } ?? "n/a"
        return "\(boundsText),on=\(onText),mem=\(memText)"
    }

    /// 產生第 2 輪 A.1 追加於第 1 輪 `| onActiveSpace=... space=...` 之後的欄位字串
    static func formatExtendedSuffix(_ f: WindowDiagExtendedFields) -> String {
        let screenIDText = f.screenID.map { "\($0)" } ?? "n/a"
        let screensText = formatScreens(f.screens)
        let activeText = formatActiveDisplays(f.activeDisplays)
        let behaviorHex = String(format: "0x%x", f.collectionBehaviorRaw)
        let parentText = f.parentWindowNumber.map { "\($0)" } ?? "none"
        let childrenText = f.childWindowNumbers.isEmpty ? "none" : f.childWindowNumbers.map { "\($0)" }.joined(separator: ",")
        let wnChangedSegment: String
        if let prev = f.previousWindowNumber, prev != f.windowNumber {
            wnChangedSegment = " wnChanged=\(prev)->\(f.windowNumber)"
        } else {
            wnChangedSegment = ""
        }
        let cgAllText = formatCGAll(f.cgAll)
        return " | frame=\(f.frame.formatted) screenID=\(screenIDText) screens=\(screensText) activeDisplays=\(activeText) frameInUnion=\(f.frameInUnion) isVisible=\(f.isVisible) isMiniaturized=\(f.isMiniaturized) appHidden=\(f.appHidden) collectionBehavior=\(behaviorHex) level=\(f.level) parent=\(parentText) children=\(childrenText) wn=\(f.windowNumber)\(wnChangedSegment) cgAll=\(cgAllText)"
    }

    /// 清洗類別名稱：移除泛型角括號與非法空白／管線字元，不觸碰任何視窗標題
    static func sanitizedClassName(_ raw: String, maxLen: Int = 40) -> String {
        var name = raw
        if let genericIdx = name.firstIndex(of: "<") {
            name = String(name[..<genericIdx])
        }
        if let dotIdx = name.lastIndex(of: ".") {
            let after = name.index(after: dotIdx)
            if after < name.endIndex {
                name = String(name[after...])
            }
        }
        let cleaned = name
            .replacingOccurrences(of: #"[\s|;,]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !cleaned.isEmpty else { return "Unknown" }
        return cleaned.count > maxLen ? String(cleaned.prefix(maxLen)) : cleaned
    }
}

// MARK: - 第 2 輪 A.3：焦點／前景化呼叫來源（純通知退路版，無 swizzling；純格式化與頻率上限）

enum WindowDiagFocusEventKind: String, Equatable, Sendable {
    case appBecomeActive = "appBecomeActive"
    case appResignActive = "appResignActive"
    case winBecomeKey = "winBecomeKey"
    case winResignKey = "winResignKey"
}

enum WindowDiagCallStackFormatter {
    static let defaultMaxFrames = 6

    /// 從單行 Thread.callStackSymbols 解析純符號名稱（去掉位址、模組欄、偏移量與括號參數）
    static func parseSymbolName(from frameLine: String, maxSymbolLen: Int = 72) -> String {
        var body = frameLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "unknown" }

        // 標準 macOS backtrace_symbols 格式：<idx> <module> 0x<hex> <symbol> + <offset>
        if let hexRange = body.range(of: #"0x[0-9a-fA-F]+\s+"#, options: .regularExpression) {
            body = String(body[hexRange.upperBound...])
        }
        // 移除尾部 " + <digits>" 偏移量
        if let plusRange = body.range(of: #"\s+\+\s+\d+$"#, options: .regularExpression) {
            body = String(body[..<plusRange.lowerBound])
        }
        // 若符號含函式參數括號（非 ObjC 方括號），只留符號主體，不記參數
        if !body.hasPrefix("-["), !body.hasPrefix("+["), let parenIdx = body.firstIndex(of: "(") {
            let prefix = String(body[..<parenIdx]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                body = prefix
            }
        }
        let cleaned = body
            .replacingOccurrences(of: #"[\r\n\t|;]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "unknown" }
        return cleaned.count > maxSymbolLen ? String(cleaned.prefix(maxSymbolLen)) : cleaned
    }

    /// 擷取前 maxFrames 層符號名稱（可跳過指定內部紀錄函式關鍵字）
    static func extractSymbolNames(
        from callStackSymbols: [String],
        maxFrames: Int = defaultMaxFrames,
        skipSubstrings: [String] = []
    ) -> [String] {
        guard maxFrames > 0 else { return [] }
        var out: [String] = []
        for raw in callStackSymbols {
            let sym = parseSymbolName(from: raw)
            if skipSubstrings.contains(where: { !($0.isEmpty) && sym.contains($0) }) {
                continue
            }
            out.append(sym)
            if out.count >= maxFrames {
                break
            }
        }
        return out
    }

    static func formatFocusSourceLine(
        kind: WindowDiagFocusEventKind,
        frontAppName: String?,
        frontBundleID: String?,
        windowClass: String?,
        windowNumber: Int?,
        symbols: [String]
    ) -> String {
        let appText = sanitizeToken(frontAppName, fallback: "n/a", maxLen: 32)
        let bundleText = sanitizeToken(frontBundleID, fallback: "n/a", maxLen: 64)
        let clsText = windowClass.map { WindowDiagFieldsFormatter.sanitizedClassName($0) } ?? "n/a"
        let wnText = windowNumber.map { "\($0)" } ?? "n/a"
        let stackText = symbols.isEmpty ? "none" : symbols.prefix(defaultMaxFrames).joined(separator: ";")
        return "事件=焦點來源 | kind=\(kind.rawValue) frontApp=\(appText) frontBundle=\(bundleText) | winClass=\(clsText) wn=\(wnText) | stack=\(stackText)"
    }

    private static func sanitizeToken(_ raw: String?, fallback: String, maxLen: Int) -> String {
        guard let raw else { return fallback }
        let cleaned = raw
            .replacingOccurrences(of: #"[\r\n\t|]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return cleaned.count > maxLen ? String(cleaned.prefix(maxLen)) : cleaned
    }
}

/// 同一事件頻率上限器（最小間隔 + 滑動視窗次數上限，時鐘可注入）
struct WindowDiagRateLimiter {
    let minIntervalPerKey: TimeInterval
    let windowDuration: TimeInterval
    let maxPerKeyInWindow: Int
    let maxTotalInWindow: Int
    private let clock: @Sendable () -> TimeInterval

    private var timestampsByKey: [String: [TimeInterval]] = [:]
    private var allTimestamps: [TimeInterval] = []

    init(
        minIntervalPerKey: TimeInterval = 0.5,
        windowDuration: TimeInterval = 60.0,
        maxPerKeyInWindow: Int = 10,
        maxTotalInWindow: Int = 30,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.minIntervalPerKey = minIntervalPerKey
        self.windowDuration = windowDuration
        self.maxPerKeyInWindow = maxPerKeyInWindow
        self.maxTotalInWindow = maxTotalInWindow
        self.clock = clock
    }

    mutating func allow(key: String, at explicitNow: TimeInterval? = nil) -> Bool {
        let now = explicitNow ?? clock()
        let eps: TimeInterval = 1e-9

        allTimestamps.removeAll { now - $0 + eps >= windowDuration }
        var list = (timestampsByKey[key] ?? []).filter { now - $0 + eps < windowDuration }
        timestampsByKey[key] = list

        if let last = list.last, now - last + eps < minIntervalPerKey {
            return false
        }
        if list.count >= maxPerKeyInWindow || allTimestamps.count >= maxTotalInWindow {
            return false
        }
        list.append(now)
        timestampsByKey[key] = list
        allTimestamps.append(now)
        return true
    }

    mutating func reset() {
        timestampsByKey.removeAll()
        allTimestamps.removeAll()
    }
}

// MARK: - 第 2 輪 B：主視窗半透明掃描（純資料結構、純掃描與格式化；完全唯讀）

struct AlphaScanLayerNode: Equatable, Sendable {
    var className: String
    var isHidden: Bool
    var opacity: Double
    /// layer.presentation()?.opacity（動畫中間態時可能 < 1 而 model opacity 仍為 1.0）
    var presentationOpacity: Double?
    var animationKeys: [String]
    /// 不屬於任何子 NSView backing 的獨立子 layer（例如殘留 snapshot layer）
    var sublayers: [AlphaScanLayerNode]

    init(
        className: String = "CALayer",
        isHidden: Bool = false,
        opacity: Double = 1.0,
        presentationOpacity: Double? = nil,
        animationKeys: [String] = [],
        sublayers: [AlphaScanLayerNode] = []
    ) {
        self.className = className
        self.isHidden = isHidden
        self.opacity = opacity
        self.presentationOpacity = presentationOpacity
        self.animationKeys = animationKeys
        self.sublayers = sublayers
    }
}

struct AlphaScanViewNode: Equatable, Sendable {
    var className: String
    var isHidden: Bool
    var alphaValue: Double
    var layer: AlphaScanLayerNode?
    var subviews: [AlphaScanViewNode]

    init(
        className: String = "NSView",
        isHidden: Bool = false,
        alphaValue: Double = 1.0,
        layer: AlphaScanLayerNode? = nil,
        subviews: [AlphaScanViewNode] = []
    ) {
        self.className = className
        self.isHidden = isHidden
        self.alphaValue = alphaValue
        self.layer = layer
        self.subviews = subviews
    }
}

struct AlphaScanFinding: Equatable, Sendable {
    /// 路徑（類別名＋階層索引，如 `NSView[0]/NSSplitView[1]/L:CALayer[0]`）
    var path: String
    var viewAlpha: Double?
    var layerOpacity: Double?
    var presentationOpacity: Double?
    var animationKeys: [String]
}

struct AlphaScanResult: Equatable, Sendable {
    var findings: [AlphaScanFinding]
    var visitedNodes: Int
    var truncatedByNodeLimit: Bool
    var truncatedByFindingLimit: Bool
}

enum AlphaScanner {
    static let defaultThreshold: Double = 0.999
    static let defaultMaxFindings = 20
    static let defaultMaxVisitedNodes = 4000

    /// 共用單節點判定（供純樹與實機 NSView/CALayer 掃描共用，確保邏輯完全一致）
    static func evaluateNode(
        path: String,
        viewAlpha: Double?,
        layerOpacity: Double?,
        presentationOpacity: Double?,
        animationKeys: [String],
        threshold: Double = defaultThreshold
    ) -> AlphaScanFinding? {
        let lowView = viewAlpha.map { $0 < threshold } ?? false
        let lowLayer = layerOpacity.map { $0 < threshold } ?? false
        let lowPres = presentationOpacity.map { $0 < threshold } ?? false
        let hasAnim = !animationKeys.isEmpty
        guard lowView || lowLayer || lowPres || hasAnim else { return nil }
        return AlphaScanFinding(
            path: path,
            viewAlpha: viewAlpha,
            layerOpacity: layerOpacity,
            presentationOpacity: presentationOpacity,
            animationKeys: animationKeys
        )
    }

    /// 遞迴掃描純資料結構 view／layer 樹（跳過 hidden 節點，限制節點數與回報數上限）
    static func scan(
        root: AlphaScanViewNode,
        threshold: Double = defaultThreshold,
        maxFindings: Int = defaultMaxFindings,
        maxVisitedNodes: Int = defaultMaxVisitedNodes
    ) -> AlphaScanResult {
        var findings: [AlphaScanFinding] = []
        var visited = 0
        var truncatedByNodes = false
        var truncatedByFindings = false

        func visitLayer(_ layer: AlphaScanLayerNode, path: String) {
            if visited >= maxVisitedNodes {
                truncatedByNodes = true
                return
            }
            guard !layer.isHidden else { return }
            visited += 1

            if let finding = evaluateNode(
                path: path,
                viewAlpha: nil,
                layerOpacity: layer.opacity,
                presentationOpacity: layer.presentationOpacity,
                animationKeys: layer.animationKeys,
                threshold: threshold
            ) {
                if findings.count < maxFindings {
                    findings.append(finding)
                } else {
                    truncatedByFindings = true
                    return
                }
            }

            for (idx, sub) in layer.sublayers.enumerated() {
                if visited >= maxVisitedNodes {
                    truncatedByNodes = true
                    return
                }
                if truncatedByFindings { return }
                let cls = WindowDiagFieldsFormatter.sanitizedClassName(sub.className)
                visitLayer(sub, path: "\(path)/L:\(cls)[\(idx)]")
            }
        }

        func visitView(_ view: AlphaScanViewNode, path: String) {
            if visited >= maxVisitedNodes {
                truncatedByNodes = true
                return
            }
            guard !view.isHidden else { return }
            visited += 1

            let layer = (view.layer?.isHidden == true) ? nil : view.layer
            if let finding = evaluateNode(
                path: path,
                viewAlpha: view.alphaValue,
                layerOpacity: layer?.opacity,
                presentationOpacity: layer?.presentationOpacity,
                animationKeys: layer?.animationKeys ?? [],
                threshold: threshold
            ) {
                if findings.count < maxFindings {
                    findings.append(finding)
                } else {
                    truncatedByFindings = true
                    return
                }
            }

            for (idx, sub) in view.subviews.enumerated() {
                if visited >= maxVisitedNodes {
                    truncatedByNodes = true
                    return
                }
                if truncatedByFindings { return }
                let cls = WindowDiagFieldsFormatter.sanitizedClassName(sub.className)
                visitView(sub, path: "\(path)/\(cls)[\(idx)]")
            }

            if let layer {
                for (idx, subLayer) in layer.sublayers.enumerated() {
                    if visited >= maxVisitedNodes {
                        truncatedByNodes = true
                        return
                    }
                    if truncatedByFindings { return }
                    let cls = WindowDiagFieldsFormatter.sanitizedClassName(subLayer.className)
                    visitLayer(subLayer, path: "\(path)/L:\(cls)[\(idx)]")
                }
            }
        }

        let rootClass = WindowDiagFieldsFormatter.sanitizedClassName(root.className)
        visitView(root, path: "\(rootClass)[0]")

        return AlphaScanResult(
            findings: findings,
            visitedNodes: visited,
            truncatedByNodeLimit: truncatedByNodes,
            truncatedByFindingLimit: truncatedByFindings
        )
    }
}

enum AlphaScanFormatter {
    static let category = "視窗半透明"
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let maxPathLength = 160
    private static let maxAnimKeys = 6

    static func formatLines(
        sequence: Int,
        trigger: String,
        source: String,
        result: AlphaScanResult
    ) -> [String] {
        guard !result.findings.isEmpty else { return [] }
        let capped = Array(result.findings.prefix(AlphaScanner.defaultMaxFindings))
        let truncated = result.truncatedByNodeLimit || result.truncatedByFindingLimit || result.findings.count > capped.count
        var lines: [String] = []
        lines.append(
            "半透明#\(sequence) 開始 | 觸發=\(sanitizeToken(trigger)) 來源=\(sanitizeToken(source)) 異常數=\(capped.count) 走訪=\(result.visitedNodes) 截斷=\(truncated)"
        )
        for (idx, item) in capped.enumerated() {
            let pathText = sanitizePath(item.path)
            let vaText = fmtOpt3(item.viewAlpha)
            let loText = fmtOpt3(item.layerOpacity)
            let poText = fmtOpt3(item.presentationOpacity)
            let animText = formatAnims(item.animationKeys)
            lines.append(
                "半透明#\(sequence) 節點#\(idx + 1) | 路徑=\(pathText) viewAlpha=\(vaText) layerOpacity=\(loText) presOpacity=\(poText) anims=\(animText)"
            )
        }
        lines.append("半透明#\(sequence) 結束 | 節點數=\(capped.count)")
        return lines
    }

    static func emit(
        sequence: Int,
        trigger: String,
        source: String,
        result: AlphaScanResult,
        sink: (String, String) -> Void = { EventLog.log($0, $1) }
    ) {
        for line in formatLines(sequence: sequence, trigger: trigger, source: source, result: result) {
            sink(category, line)
        }
    }

    private static func fmtOpt3(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "n/a" }
        return String(format: "%.3f", locale: posixLocale, v)
    }

    private static func formatAnims(_ keys: [String]) -> String {
        guard !keys.isEmpty else { return "none" }
        let cleaned = keys.prefix(maxAnimKeys).map { sanitizeToken($0, maxLen: 24) }
        return cleaned.joined(separator: ",")
    }

    private static func sanitizePath(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: #"[\r\n\t| ]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Unknown[0]" }
        if cleaned.count <= maxPathLength { return cleaned }
        let headLen = 56
        let tailLen = maxPathLength - headLen - 3
        return "\(cleaned.prefix(headLen))...\(cleaned.suffix(tailLen))"
    }

    private static func sanitizeToken(_ raw: String, maxLen: Int = 32) -> String {
        let cleaned = raw
            .replacingOccurrences(of: #"[\r\n\t| ,;]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !cleaned.isEmpty else { return "unknown" }
        return cleaned.count > maxLen ? String(cleaned.prefix(maxLen)) : cleaned
    }
}
